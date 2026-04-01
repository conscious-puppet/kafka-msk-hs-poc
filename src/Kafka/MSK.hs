{- HLINT ignore "Use toString" -}

module Kafka.MSK (
  runMSKConsumer,
  KafkaConfig (..),
)
where

import AWS.Auth (IAMToken (..), generateIAMToken, isAuthError)
import Control.Exception (bracket, throwIO)
import Data.Text qualified as T
import Kafka.Consumer
import System.IO.Error (userError)

data KafkaConfig = KafkaConfig
  { bootstrapServers :: Text
  , topic :: Text
  , consumerGroupId :: Text
  , region :: Text
  }

{- | Run the MSK consumer with automatic reconnection on auth errors
Returns Left on auth error (caller should reconnect), throws on other errors
-}
runMSKConsumer :: KafkaConfig -> TVar IAMToken -> IO (Either KafkaError ())
runMSKConsumer config tokenVar = do
  -- Get current token and generate Kafka credentials
  token <- readTVarIO tokenVar
  (username, password) <- generateIAMToken token (extractBrokerHost $ bootstrapServers config) (region config)

  let props = mkConsumerProps config username password
      sub = mkSubscription config

  bracket
    ( do
        putStrLn "[Kafka.MSK] Creating Kafka consumer..."
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
          if isAuthError err
            then pure $ Left err
            else throwIO $ userError $ "Fatal error creating consumer: " <> show err
        Right consumer -> do
          putStrLn "[Kafka.MSK] Consumer created, starting poll loop..."
          pollLoop tokenVar consumer
    )

{- | Continuous polling loop that handles auth errors gracefully
Returns Left on auth error, throws on fatal errors
-}
pollLoop :: TVar IAMToken -> KafkaConsumer -> IO (Either KafkaError ())
pollLoop tokenVar consumer = go
  where
    go = do
      -- Check for token refresh (get current credentials)
      _token <- readTVarIO tokenVar

      -- Poll for message with 10 second timeout
      msg <- pollMessage consumer (Timeout 10000)

      case msg of
        Left err -> do
          putStrLn $ "[Kafka.MSK] Poll error: " <> show err
          if isAuthError err
            then do
              putStrLn "[Kafka.MSK] Authentication error detected, will reconnect"
              pure $ Left err
            else do
              putStrLn $ "[Kafka.MSK] Fatal error: " <> show err
              throwIO $ userError $ "Fatal consumer error: " <> show err
        Right record -> do
          -- Print the message
          case crValue record of
            Nothing -> putStrLn "[Kafka.MSK] Received message with no value"
            Just bs -> putStrLn $ "[Kafka.MSK] Received message: " <> T.unpack (decodeUtf8 bs)

          -- Continue polling (no offset commit, will re-read from earliest on restart)
          go

-- | Extract host from "host:port" format
extractBrokerHost :: Text -> Text
extractBrokerHost = T.takeWhile (/= ':')

mkConsumerProps :: KafkaConfig -> Text -> Text -> ConsumerProperties
mkConsumerProps config username password =
  brokersList [BrokerAddress $ bootstrapServers config]
    <> groupId (ConsumerGroupId $ consumerGroupId config)
    <> noAutoCommit
    <> extraProp "security.protocol" "sasl_ssl"
    <> extraProp "sasl.mechanism" "PLAIN"
    <> extraProp "sasl.username" username
    <> extraProp "sasl.password" password
    <> extraProp "enable.auto.commit" "false"
    <> extraProp "auto.offset.reset" "earliest"

mkSubscription :: KafkaConfig -> Subscription
mkSubscription config =
  topics [TopicName $ topic config]
    <> offsetReset Earliest
