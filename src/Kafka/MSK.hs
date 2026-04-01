{- HLINT ignore "Use toString" -}

module Kafka.MSK (
  runMSKConsumer,
  KafkaConfig (..),
)
where

import AWS.Auth (IAMToken (..), isAuthError)
import Control.Exception (bracket, throwIO)
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
runMSKConsumer config _tokenVar = do
  -- No token generation needed - kafka-proxy handles auth
  putStrLn "[Kafka.MSK] Connecting to kafka-proxy on localhost:9092 (no auth required)"

  let props = mkConsumerProps config
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
          isAuth <- isAuthError err
          if isAuth
            then pure $ Left err
            else throwIO $ userError $ "Fatal error creating consumer: " <> show err
        Right consumer -> do
          putStrLn "[Kafka.MSK] Consumer created, starting poll loop..."
          pollLoop consumer
    )

{- | Continuous polling loop that handles auth errors gracefully
Returns Left on auth error, throws on fatal errors
-}
pollLoop :: KafkaConsumer -> IO (Either KafkaError ())
pollLoop consumer = go
  where
    go = do
      -- Poll for message with 10 second timeout
      msg <- pollMessage consumer (Timeout 10000)

      case msg of
        Left err -> do
          putStrLn $ "[Kafka.MSK] Poll error: " <> show err
          isAuth <- isAuthError err
          if isAuth
            then do
              putStrLn "[Kafka.MSK] Authentication error detected, will reconnect"
              pure $ Left err
            else do
              -- For POC: log error and continue polling instead of crashing
              putStrLn $ "[Kafka.MSK] Non-auth error, continuing: " <> show err
              go
        Right record -> do
          -- Print the message
          case crValue record of
            Nothing -> putStrLn "[Kafka.MSK] Received message with no value"
            Just bs -> do
              putStrLn "[Kafka.MSK] =============================="
              putStrLn "[Kafka.MSK] RECEIVED MESSAGE:"
              putStrLn "[Kafka.MSK] =============================="
              putStrLn $ "[Kafka.MSK] " <> show bs
              putStrLn "[Kafka.MSK] =============================="

          -- Continue polling (no offset commit, will re-read from earliest on restart)
          go

mkConsumerProps :: KafkaConfig -> ConsumerProperties
mkConsumerProps config =
  brokersList [BrokerAddress $ bootstrapServers config]
    <> groupId (ConsumerGroupId $ consumerGroupId config)
    <> noAutoCommit
    -- Connect to kafka-proxy on localhost with PLAINTEXT (no auth)
    -- The proxy handles MSK IAM auth, clients connect without SASL
    <> extraProp "security.protocol" "plaintext"
    <> extraProp "enable.auto.commit" "false"
    <> extraProp "auto.offset.reset" "earliest"

mkSubscription :: KafkaConfig -> Subscription
mkSubscription config =
  topics [TopicName $ topic config]
    <> offsetReset Earliest
