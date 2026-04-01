module AWS.Auth (
  IAMToken (..),
  assumeRole,
  generateIAMToken,
  startTokenRefresher,
  isAuthError,
)
where

import Amazonka (LogLevel (..), Region, newEnv, runResourceT, send)
import Amazonka.Auth (discover)
import Amazonka.Crypto (hashSHA256, hmacSHA256)
import Amazonka.Data.Sensitive (Sensitive (..), fromSensitive)
import Amazonka.Data.Time (Time (..))
import Amazonka.Env (logger)
import Amazonka.Logger (newLogger)
import Amazonka.STS (newAssumeRole)
import Amazonka.STS.AssumeRole (AssumeRoleResponse (..))
import Amazonka.Types (AccessKey (..), AuthEnv (..), SecretKey (..), SessionToken (..))
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, async)
import Data.ByteArray (ByteArrayAccess, convert)
import Data.ByteArray.Encoding qualified as BA
import Data.ByteString.Char8 qualified as B8
import Data.Text (isInfixOf, toLower)
import Data.Time.Clock (UTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Kafka.Consumer (KafkaError (..))
import Network.HTTP.Types.URI (urlEncode)

-- | AWS credentials obtained from STS AssumeRole
data IAMToken = IAMToken
  { iamAccessKeyId :: Text
  , iamSecretAccessKey :: Text
  , iamSessionToken :: Text
  , iamExpiration :: UTCTime
  }
  deriving stock (Show)

-- | Assume a role using STS and return the credentials
assumeRole :: Text -> Text -> Region -> IO IAMToken
assumeRole roleArn sessionName _region = do
  putStrLn $ "[AWS.Auth] Assuming role: " <> toString roleArn
  putStrLn "[AWS.Auth] Setting up debug logger..."

  -- Create a logger that outputs to stderr
  debugLogger <- newLogger Debug stderr

  -- Build the AssumeRole request
  let req = newAssumeRole roleArn sessionName

  -- Execute the request
  resp <- runResourceT $ do
    -- Create environment with debug logging
    env <- newEnv discover
    let envWithLogger = env {logger = debugLogger}
    putStrLn "[AWS.Auth] Env created with debug logging, sending request..."
    send envWithLogger req

  -- Extract credentials from response
  let authEnv = credentials resp

  -- Convert AuthEnv to IAMToken
  -- Unwrap the newtypes and Sensitive wrapper
  now <- getCurrentTime
  let token =
        IAMToken
          { iamAccessKeyId = decodeUtf8 (fromAccessKey $ accessKeyId authEnv)
          , iamSecretAccessKey = decodeUtf8 (fromSecretKey $ fromSensitive $ secretAccessKey authEnv)
          , iamSessionToken = maybe "" (decodeUtf8 . fromSessionToken . fromSensitive) (sessionToken authEnv)
          , iamExpiration = maybe now (\(Time t) -> t) (expiration authEnv)
          }

  putStrLn $ "[AWS.Auth] Role assumed successfully, expires at: " <> show (iamExpiration token)
  pure token
  where
    fromAccessKey (AccessKey bs) = bs
    fromSecretKey (SecretKey bs) = bs
    fromSessionToken (SessionToken bs) = bs

{- | Generate IAM token for MSK SASL/PLAIN authentication
Returns (username, password) where username is the access key ID
and password is the signed URL for kafka-cluster:Bootstrap action
-}
generateIAMToken :: IAMToken -> Text -> Text -> IO (Text, Text)
generateIAMToken token brokerHost region = do
  now <- getCurrentTime
  let dateStr = formatTime defaultTimeLocale "%Y%m%dT%H%M%SZ" now
      dateStamp = formatTime defaultTimeLocale "%Y%m%d" now

      service = "kafka-cluster"
      algorithm = "AWS4-HMAC-SHA256"

      canonicalUri = "/"
      canonicalQueryString = "Action=Bootstrap"

      hostHeader = "host:" <> toString brokerHost
      xAmzDateHeader = "x-amz-date:" <> dateStr
      xAmzSecurityTokenHeader = "x-amz-security-token:" <> toString (urlEncodeText $ iamSessionToken token)

      signedHeaders = "host;x-amz-date;x-amz-security-token"
      canonicalHeaders = hostHeader <> "\n" <> xAmzDateHeader <> "\n" <> xAmzSecurityTokenHeader <> "\n"

      canonicalRequest =
        "GET\n"
          <> canonicalUri
          <> "\n"
          <> canonicalQueryString
          <> "\n"
          <> canonicalHeaders
          <> "\n"
          <> signedHeaders
          <> "\n"
          <> "UNSIGNED-PAYLOAD"

      credentialScope = dateStamp <> "/" <> toString region <> "/" <> service <> "/aws4_request"

      stringToSign =
        algorithm
          <> "\n"
          <> dateStr
          <> "\n"
          <> credentialScope
          <> "\n"
          <> digestToHex (hashSHA256 $ B8.pack canonicalRequest)

      signingKey = deriveSigningKey (encodeUtf8 $ iamSecretAccessKey token) dateStamp (toString region) service
      signature = digestToHex $ hmacSHA256 signingKey (B8.pack stringToSign)

      saslPassword =
        "host="
          <> toString brokerHost
          <> "&x-amz-date="
          <> dateStr
          <> "&x-amz-security-token="
          <> toString (urlEncodeText $ iamSessionToken token)
          <> "&x-amz-credential="
          <> toString (urlEncodeText $ iamAccessKeyId token <> "/" <> toText dateStamp <> "/" <> region <> "/" <> toText service <> "/aws4_request")
          <> "&x-amz-signedheaders="
          <> signedHeaders
          <> "&x-amz-algorithm="
          <> algorithm
          <> "&x-amz-signature="
          <> signature

  pure (iamAccessKeyId token, toText saslPassword)
  where
    urlEncodeText :: Text -> Text
    urlEncodeText = decodeUtf8 . urlEncode False . encodeUtf8

    digestToHex :: (ByteArrayAccess a) => a -> String
    digestToHex = B8.unpack . BA.convertToBase BA.Base16

    deriveSigningKey :: ByteString -> String -> String -> String -> ByteString
    deriveSigningKey secretKey date region' service' =
      let kDate = convert $ hmacSHA256 (B8.pack $ "AWS4" <> B8.unpack secretKey) (B8.pack date)
          kRegion = convert $ hmacSHA256 kDate (B8.pack region')
          kService = convert $ hmacSHA256 kRegion (B8.pack service')
          kSigning = convert $ hmacSHA256 kService (B8.pack "aws4_request")
       in kSigning

{- HLINT ignore startTokenRefresher "Use infinitely" -}

{- | Start a background thread that refreshes the token every 10 seconds
This calls STS AssumeRole and updates the TVar
-}
startTokenRefresher :: TVar IAMToken -> Text -> Text -> Region -> IO (Async ())
startTokenRefresher tokenVar roleArn sessionName region = do
  putStrLn "[TokenRefresher] Starting token refresh thread (interval: 10 seconds)"
  async $ forever $ do
    timestamp <- getCurrentTime
    putStrLn $ "[TokenRefresher] Refreshing token at " <> show timestamp

    -- Call STS to get fresh credentials
    token <- assumeRole roleArn sessionName region

    -- Update the TVar
    atomically $ writeTVar tokenVar token

    putStrLn $ "[TokenRefresher] Token refreshed successfully, expires at: " <> show (iamExpiration token)

    -- Wait 10 seconds before next refresh
    threadDelay (10 * 1000000)

{- | Check if a KafkaError is an authentication error
Logs each check attempt for debugging
-}
isAuthError :: KafkaError -> IO Bool
isAuthError err@(KafkaError msg) = do
  putStrLn $ "[AWS.Auth.isAuthError] Checking KafkaError: " <> show err
  let msgLower = toLower msg
      result
        | "authentication" `isInfixOf` msgLower = True
        | "auth" `isInfixOf` msgLower = True
        | "sasl" `isInfixOf` msgLower = True
        | "credential" `isInfixOf` msgLower = True
        | "token" `isInfixOf` msgLower = True
        | otherwise = False
  putStrLn $ "[AWS.Auth.isAuthError] Result: " <> show result <> ", msg: " <> show msg
  pure result
isAuthError err@(KafkaResponseError _) = do
  putStrLn $ "[AWS.Auth.isAuthError] Found KafkaResponseError: " <> show err
  pure True
isAuthError err = do
  putStrLn $ "[AWS.Auth.isAuthError] Not an auth error: " <> show err
  pure False
