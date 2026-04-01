module Config (
  Config (..),
  loadConfig,
)
where

import Control.Exception (throwIO)
import System.IO.Error (userError)

data Config = Config
  { awsRoleArn :: Text
  , awsSessionName :: Text
  , mskBootstrapServers :: Text
  , mskTopic :: Text
  , mskRegion :: Text
  }
  deriving stock (Show, Eq)

loadConfig :: IO Config
loadConfig = do
  awsRoleArn <- getEnvVar "AWS_ROLE_ARN"
  awsSessionName <- fromMaybe "kafka-haskell-poc" <$> lookupEnvText "AWS_SESSION_NAME"
  -- Use PROXY_BOOTSTRAP_SERVERS if available (for kafka-proxy), otherwise fall back to MSK_BOOTSTRAP_SERVERS
  mskBootstrapServers <-
    lookupEnvText "PROXY_BOOTSTRAP_SERVERS" >>= \case
      Just proxyServers -> do
        putStrLn $ "[Config] Using proxy bootstrap servers: " <> toString proxyServers
        pure proxyServers
      Nothing -> do
        putStrLn "[Config] Using direct MSK bootstrap servers"
        getEnvVar "MSK_BOOTSTRAP_SERVERS"
  mskTopic <- getEnvVar "MSK_TOPIC"
  mskRegion <- fromMaybe "ap-south-1" <$> lookupEnvText "MSK_REGION"
  pure Config {..}

getEnvVar :: String -> IO Text
getEnvVar name =
  lookupEnv name >>= \case
    Nothing -> throwIO $ userError $ "Environment variable " <> name <> " is required"
    Just val -> pure $ toText val

lookupEnvText :: String -> IO (Maybe Text)
lookupEnvText name = fmap toText <$> lookupEnv name
