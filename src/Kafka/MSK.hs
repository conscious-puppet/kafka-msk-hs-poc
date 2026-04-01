{- HLINT ignore "Use toString" -}

module Kafka.MSK (
  runMSKConsumer,
  KafkaConfig (..),
)
where

import AWS.Auth (IAMToken (..), assumeRole, generateMSKToken)
import Amazonka (Region (..))
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel)
import Control.Exception (bracket, finally)
import Data.Text (Text)
import Data.Text qualified as Text
import Kafka.Consumer
import Kafka.OAuthBearer (
  OAuthBearerToken (..),
  setOAuthBearerToken,
 )

data KafkaConfig = KafkaConfig
  { bootstrapServers :: Text
  , topic :: Text
  , consumerGroupId :: Text
  , region :: Text
  , awsRoleArn :: Text
  , awsSessionName :: Text
  }

-- | Run the MSK consumer with native OAuthBearer authentication
runMSKConsumer :: KafkaConfig -> IO ()
runMSKConsumer config = do
  putStrLn "[Kafka.MSK] Connecting to MSK with native OAuthBearer authentication"
  putStrLn $ "[Kafka.MSK] Bootstrap: " <> Text.unpack (bootstrapServers config)

  -- Extract broker host from bootstrap servers
  let brokerHost = Text.takeWhile (/= ':') (bootstrapServers config)

  -- Create TVar for token storage
  let awsRegion = Region' (region config)
  tokenVar <- newTVarIO =<< assumeRole (awsRoleArn config) (awsSessionName config) awsRegion

  -- Start token refresher thread
  refresher <- async $ tokenRefresher tokenVar (awsRoleArn config) (awsSessionName config) awsRegion

  let props = mkConsumerProps config
      sub = mkSubscription config

  flip finally (cancel refresher) $
    bracket
      ( do
          putStrLn "[Kafka.MSK] Creating Kafka consumer with OAuthBearer..."
          newConsumer props sub
      )
      ( \case
          Left _ -> pass
          Right kc -> do
            putStrLn "[Kafka.MSK] Closing Kafka consumer"
            void $ closeConsumer kc
      )
      ( \case
          Left err -> do
            putStrLn $ "[Kafka.MSK] Failed to create consumer: " <> show err
            error $ "Fatal error: " <> show err
          Right consumer -> do
            putStrLn "[Kafka.MSK] Consumer created, starting poll loop..."
            -- Set initial OAuth token
            setInitialToken consumer tokenVar brokerHost (region config)
            pollLoop consumer tokenVar brokerHost (region config)
      )
  where
    tokenRefresher tv roleArn sessionName awsRegion = forever $ do
      threadDelay (10 * 60 * 1000000) -- 10 minutes
      newToken <- assumeRole roleArn sessionName awsRegion
      atomically $ writeTVar tv newToken
      putStrLn "[Kafka.MSK] Token refreshed in background"

    setInitialToken consumer tv brokerHost awsRegion = do
      token <- readTVarIO tv
      oauthToken <- generateMSKToken token brokerHost awsRegion
      let oauthBearerToken =
            OAuthBearerToken
              { tokenValue = oauthToken
              , lifetimeMs = 3600000 -- 1 hour
              , principalName = iamAccessKeyId token
              , extensions = []
              }
      result <- setOAuthBearerToken consumer oauthBearerToken
      case result of
        Left err -> putStrLn $ "[Kafka.MSK] Warning: Failed to set initial token: " <> show err
        Right () -> putStrLn "[Kafka.MSK] Initial OAuth token set successfully"

-- | Continuous polling loop with token refresh
pollLoop :: KafkaConsumer -> TVar IAMToken -> Text -> Text -> IO ()
pollLoop consumer tokenVar brokerHost region = go
  where
    go = do
      msg <- pollMessage consumer (Timeout 10000)
      case msg of
        Left err -> do
          putStrLn $ "[Kafka.MSK] Poll error: " <> show err
          -- On auth error, try refreshing the token
          refreshAndContinue err
        Right record -> do
          case crValue record of
            Nothing -> putStrLn "[Kafka.MSK] Received message with no value"
            Just bs -> do
              putStrLn "[Kafka.MSK] ==============================="
              putStrLn "[Kafka.MSK] RECEIVED MESSAGE:"
              putStrLn "[Kafka.MSK] ==============================="
              putStrLn $ "[Kafka.MSK] " <> show bs
              putStrLn "[Kafka.MSK] ==============================="
          go

    refreshAndContinue err = do
      -- Check if it's an authentication error
      case err of
        KafkaResponseError authErr | isAuthError authErr -> do
          putStrLn "[Kafka.MSK] Auth error detected, refreshing token..."
          token <- readTVarIO tokenVar
          oauthToken <- generateMSKToken token brokerHost region
          let oauthBearerToken =
                OAuthBearerToken
                  { tokenValue = oauthToken
                  , lifetimeMs = 3600000
                  , principalName = iamAccessKeyId token
                  , extensions = []
                  }
          result <- setOAuthBearerToken consumer oauthBearerToken
          case result of
            Left tokenErr -> putStrLn $ "[Kafka.MSK] Failed to refresh token: " <> show tokenErr
            Right () -> putStrLn "[Kafka.MSK] Token refreshed successfully"
        _ -> pass
      go

    -- Check if error is authentication-related
    isAuthError :: RdKafkaRespErrT -> Bool
    isAuthError err =
      err
        `elem` [ RdKafkaRespErrAuthentication
               ]

mkConsumerProps :: KafkaConfig -> ConsumerProperties
mkConsumerProps config =
  brokersList [BrokerAddress $ bootstrapServers config]
    <> groupId (ConsumerGroupId $ consumerGroupId config)
    <> noAutoCommit
    -- Use SASL_SSL with OAUTHBEARER for MSK IAM authentication
    <> extraProp "security.protocol" "SASL_SSL"
    <> extraProp "sasl.mechanism" "OAUTHBEARER"
    <> extraProp "enable.auto.commit" "false"
    <> extraProp "auto.offset.reset" "earliest"

mkSubscription :: KafkaConfig -> Subscription
mkSubscription config =
  topics [TopicName $ topic config]
    <> offsetReset Earliest
