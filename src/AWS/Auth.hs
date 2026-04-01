module AWS.Auth (
  IAMToken (..),
  assumeRole,
  generateMSKToken,
)
where

import Amazonka (LogLevel (..), Region, newEnv, runResourceT, send)
import Amazonka.Auth (discover)
import Amazonka.Data.Sensitive (fromSensitive)
import Amazonka.Data.Time (Time (..))
import Amazonka.Env (logger)
import Amazonka.Env qualified as Env
import Amazonka.Logger (newLogger)
import Amazonka.STS (newAssumeRole)
import Amazonka.STS.AssumeRole (AssumeRoleResponse (..))
import Amazonka.Types (AccessKey (..), AuthEnv (..), SecretKey (..), SessionToken (..))
import Data.ByteString.Char8 qualified as B8
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (UTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)

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
assumeRole roleArn sessionName region = do
  putStrLn $ "[AWS.Auth] Assuming role: " <> Text.unpack roleArn
  putStrLn $ "[AWS.Auth] Using region: " <> show region

  -- Create a logger that outputs to stderr
  debugLogger <- newLogger Debug stderr

  -- Build the AssumeRole request
  let req = newAssumeRole roleArn sessionName

  -- Execute the request
  resp <- runResourceT $ do
    env <- newEnv discover
    let envWithConfig = (env {logger = debugLogger}) {Env.region = region}
    putStrLn "[AWS.Auth] Sending STS AssumeRole request..."
    send envWithConfig req

  -- Extract credentials from response
  let authEnv = credentials resp

  -- Convert AuthEnv to IAMToken
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

{- | Generate OAuthBearer token for MSK IAM authentication
This creates a signed URL token that can be used with OAUTHBEARER SASL mechanism
Note: MSK IAM with OAUTHBEARER uses a special token format (signed URL, not JWT)
-}
generateMSKToken :: IAMToken -> Text -> Text -> IO Text
generateMSKToken token brokerHost region = do
  now <- getCurrentTime
  let dateStr = formatTime defaultTimeLocale "%Y%m%dT%H%M%SZ" now

  -- For MSK IAM with OAUTHBEARER, we need to create a signed request
  -- This is a simplified version - the actual implementation would need
  -- proper AWS SigV4 signing similar to what kafka-proxy does internally
  --
  -- The token format for MSK IAM is actually a signed URL:
  -- Action=Bootstrap&X-Amz-Algorithm=AWS4-HMAC-SHA256&...
  --
  -- For this POC, we'll use a placeholder that shows the structure
  -- In production, you'd use the AWS MSK IAM signer logic

  let tokenValue =
        Text.unlines
          [ "host=" <> brokerHost
          , "x-amz-date=" <> Text.pack dateStr
          , "x-amz-security-token=" <> iamSessionToken token
          , "x-amz-credential=" <> iamAccessKeyId token <> "/" <> Text.pack (formatTime defaultTimeLocale "%Y%m%d" now) <> "/" <> region <> "/kafka-cluster/aws4_request"
          , "Action=Bootstrap"
          ]

  putStrLn "[AWS.Auth] Generated MSK OAuth token"
  pure tokenValue
