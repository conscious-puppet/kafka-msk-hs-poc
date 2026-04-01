module AWS.Auth (
  IAMToken (..),
  assumeRole,
  generateMSKToken,
)
where

import Amazonka (LogLevel (..), Region (..), configureService, newEnv, runResourceT, send)
import Amazonka.Auth (discover)
import Amazonka.Data.ByteString (toBS)
import Amazonka.Data.Sensitive (fromSensitive)
import Amazonka.Data.Time (Time (..))
import Amazonka.Env (logger)
import Amazonka.Env qualified as Env
import Amazonka.Logger (newLogger)
import Amazonka.STS (defaultService, newAssumeRole)
import Amazonka.STS.AssumeRole (AssumeRoleResponse (..))
import Amazonka.Types (AccessKey (..), AuthEnv (..), Endpoint (..), SecretKey (..), Service (..), SessionToken (..))
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

{- | Assume a role using STS and return the credentials
Uses regional STS endpoint with correct signing scope
-}
assumeRole :: Text -> Text -> Region -> IO IAMToken
assumeRole roleArn sessionName region = do
  putStrLn $ "[AWS.Auth] Assuming role: " <> toString roleArn
  putStrLn $ "[AWS.Auth] Using region: " <> show region

  -- Create a logger that outputs to stderr
  debugLogger <- newLogger Debug stderr

  -- Build the AssumeRole request
  let req = newAssumeRole roleArn sessionName

  -- Execute the request
  resp <- runResourceT $ do
    env <- newEnv discover
    let envWithRegion = (env {logger = debugLogger}) {Env.region = region}

    -- Configure STS to use regional endpoint with correct signing scope
    -- The key is to set the 'scope' field in Endpoint to the region for correct signing
    let stsEndpointHost = encodeUtf8 $ "sts." <> fromRegion region <> ".amazonaws.com"
    let stsService =
          defaultService
            { endpoint =
                const $
                  Endpoint
                    { host = stsEndpointHost
                    , basePath = mempty
                    , secure = True
                    , port = 443
                    , scope = toBS region -- This is crucial: sets the signing region!
                    }
            }
    let envWithSTS = configureService stsService envWithRegion

    putStrLn $ "[AWS.Auth] Using STS regional endpoint: " <> decodeUtf8 stsEndpointHost
    putStrLn $ "[AWS.Auth] Signing scope (region): " <> decodeUtf8 (toBS region)
    send envWithSTS req

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
    fromRegion (Region' r) = r

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
        unlines
          [ "host=" <> brokerHost
          , "x-amz-date=" <> toText dateStr
          , "x-amz-security-token=" <> iamSessionToken token
          , "x-amz-credential=" <> iamAccessKeyId token <> "/" <> toText (formatTime defaultTimeLocale "%Y%m%d" now) <> "/" <> region <> "/kafka-cluster/aws4_request"
          , "Action=Bootstrap"
          ]

  putStrLn "[AWS.Auth] Generated MSK OAuth token"
  pure tokenValue
