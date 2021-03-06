{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}

module Tickler.Server.OptParse
  ( module Tickler.Server.OptParse
  , module Tickler.Server.OptParse.Types
  ) where

import Import

import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Text.Read

import qualified System.Environment as System

import Control.Monad.Trans.AWS as AWS
import Database.Persist.Sqlite

import Options.Applicative

import Web.Stripe.Client as Stripe
import Web.Stripe.Types as Stripe

import Tickler.API
import Tickler.Server.OptParse.Types

getInstructions :: IO Instructions
getInstructions = do
  Arguments cmd flags <- getArguments
  config <- getConfiguration cmd flags
  env <- getEnvironment
  combineToInstructions cmd flags config env

combineToInstructions :: Command -> Flags -> Configuration -> Environment -> IO Instructions
combineToInstructions (CommandServe ServeFlags {..}) Flags Configuration Environment {..} = do
  let serveSetPort = fromMaybe 8001 $ serveFlagPort `mplus` envPort
  webHost <-
    case serveFlagWebHost `mplus` envWebHost of
      Nothing -> die "No web host configured."
      Just wh -> pure $ T.pack wh
  dbPath <- resolveFile' $ fromMaybe "tickler.db" $ serveFlagDb <> envDb
  let serveSetConnectionInfo = mkSqliteConnectionInfo $ T.pack $ fromAbsFile dbPath
  serveSetAdmins <-
    forM serveFlagAdmins $ \s ->
      case parseUsername $ T.pack s of
        Nothing -> die $ unwords ["Invalid admin username:", s]
        Just u -> pure u
  let LooperFlags {..} = serveFlagsLooperFlags
  let LoopersEnvironment {..} = envLoopersEnvironment
  let defaultLoopersEnabled =
        fromMaybe True $ looperFlagDefaultEnabled `mplus` looperEnvDefaultEnabled
  let defaultLoopersPeriod = fromMaybe 60 $ looperFlagDefaultPeriod `mplus` looperEnvDefaultPeriod
  let defaultLooperRetryDelay =
        fromMaybe 1000000 $ looperFlagDefaultRetryDelay `mplus` looperEnvDefaultRetryDelay
  let defaultLooperRetryAmount =
        fromMaybe 7 $ looperFlagDefaultRetryTimes `mplus` looperEnvDefaultRetryTimes
  let combineToLooperSets ::
           LooperFlagsWith a -> LooperEnvWith b -> (a -> b -> IO c) -> IO (LooperSetsWith c)
      combineToLooperSets LooperFlagsWith {..} LooperEnvWith {..} func = do
        let enabled = fromMaybe defaultLoopersEnabled $ looperFlagEnable `mplus` looperEnvEnable
        if enabled
          then do
            let LooperFlagsRetryPolicy {..} = looperFlagsRetryPolicy
            let LooperEnvRetryPolicy {..} = looperEnvRetryPolicy
            let static =
                  LooperStaticConfig
                    { looperStaticConfigPeriod =
                        fromMaybe defaultLoopersPeriod $ looperFlagsPeriod `mplus` looperEnvPeriod
                    , looperStaticConfigRetryPolicy =
                        LooperRetryPolicy
                          { looperRetryPolicyDelay =
                              fromMaybe defaultLooperRetryDelay $
                              looperFlagsRetryDelay `mplus` looperEnvRetryDelay
                          , looperRetryPolicyAmount =
                              fromMaybe defaultLooperRetryAmount $
                              looperFlagsRetryAmount `mplus` looperEnvRetryAmount
                          }
                    }
            LooperEnabled static <$> func looperFlags looperEnv
          else pure LooperDisabled
  serveSetLooperSettings <-
    do looperSetTriggererSets <-
         combineToLooperSets looperFlagTriggererFlags looperEnvTriggererEnv $
         const $ const $ pure TriggererSettings
       looperSetEmailerSets <-
         combineToLooperSets looperFlagEmailerFlags looperEnvEmailerEnv $
         const $ const $ pure $ EmailerSettings AWS.Discover
       looperSetTriggeredIntrayItemSchedulerSets <-
         combineToLooperSets
           looperFlagTriggeredIntrayItemSchedulerFlags
           looperEnvTriggeredIntrayItemSchedulerEnv $
         const $ const $ pure ()
       looperSetTriggeredIntrayItemSenderSets <-
         combineToLooperSets
           looperFlagTriggeredIntrayItemSenderFlags
           looperEnvTriggeredIntrayItemSenderEnv $
         const $ const $ pure ()
       looperSetVerificationEmailConverterSets <-
         combineToLooperSets
           looperFlagVerificationEmailConverterFlags
           looperEnvVerificationEmailConverterEnv $ \f e -> do
           ea <-
             case f <|> e of
               Nothing -> die "No email configured for the email triggerer"
               Just ea -> pure ea
           pure
             VerificationEmailConverterSettings
               { verificationEmailConverterSetFromAddress = ea
               , verificationEmailConverterSetFromName = "Tickler Verification"
               , verificationEmailConverterSetWebHost = webHost
               }
       looperSetTriggeredEmailSchedulerSets <-
         combineToLooperSets
           looperFlagTriggeredEmailSchedulerFlags
           looperEnvTriggeredEmailSchedulerEnv $
         const $ const $ pure ()
       looperSetTriggeredEmailConverterSets <-
         combineToLooperSets
           looperFlagTriggeredEmailConverterFlags
           looperEnvTriggeredEmailConverterEnv $ \f e -> do
           ea <-
             case f <|> e of
               Nothing -> die "No email configured for the email triggerer"
               Just ea -> pure ea
           pure
             TriggeredEmailConverterSettings
               { triggeredEmailConverterSetFromAddress = ea
               , triggeredEmailConverterSetFromName = "Tickler Triggerer"
               , triggeredEmailConverterSetWebHost = webHost
               }
       pure LooperSettings {..}
  serveSetMonetisationSettings <-
    do let MonetisationFlags {..} = serveFlagsMonetisationFlags
       let MonetisationEnvironment {..} = envMonetisationEnvironment
       let plan =
             Stripe.PlanId . T.pack <$> (monetisationFlagStripePlan <|> monetisationEnvStripePlan)
       let config =
             (\sk ->
                StripeConfig
                  { Stripe.secretKey = StripeKey $ TE.encodeUtf8 $ T.pack sk
                  , stripeEndpoint = Nothing
                  }) <$>
             (monetisationFlagStripeSecretKey <|> monetisationEnvStripeSecretKey)
       let publicKey =
             T.pack <$>
             (monetisationFlagStripePublishableKey <|> monetisationEnvStripePulishableKey)
       monetisationSetStripeEventsFetcher <-
         combineToLooperSets
           monetisationFlagLooperStripeEventsFetcher
           monetisationEnvLooperStripeEventsFetcher $
         const $ const $ pure ()
       monetisationSetStripeEventsRetrier <-
         combineToLooperSets
           monetisationFlagLooperStripeEventsRetrier
           monetisationEnvLooperStripeEventsRetrier $
         const $ const $ pure ()
       let monetisationSetMaxItemsFree =
             fromMaybe 5 $ monetisationFlagMaxItemsFree <|> monetisationEnvMaxItemsFree
       pure $
         MonetisationSettings <$> (StripeSettings <$> plan <*> config <*> publicKey) <*>
         pure monetisationSetStripeEventsFetcher <*>
         pure monetisationSetStripeEventsRetrier <*>
         pure monetisationSetMaxItemsFree
  pure $ Instructions (DispatchServe ServeSettings {..}) Settings

getConfiguration :: Command -> Flags -> IO Configuration
getConfiguration _ _ = pure Configuration

getEnvironment :: IO Environment
getEnvironment = do
  env <- System.getEnvironment
  let envDb = getEnv env "DATABASE"
  let envWebHost = getEnv env "WEB_HOST"
  envPort <- readEnv env "PORT"
  envMonetisationEnvironment <- getMonetisationEnv env
  envLoopersEnvironment <- getLoopersEnv env
  pure Environment {..}

getMonetisationEnv :: [(String, String)] -> IO MonetisationEnvironment
getMonetisationEnv env = do
  let monetisationEnvStripePlan = getEnv env "STRIPE_PLAN"
  let monetisationEnvStripeSecretKey = getEnv env "STRIPE_SECRET_KEY"
  let monetisationEnvStripePulishableKey = getEnv env "STRIPE_PUBLISHABLE_KEY"
  monetisationEnvLooperStripeEventsFetcher <- getLooperEnvWith env "STRIPE_EVENTS_FETCHER" $ pure ()
  monetisationEnvLooperStripeEventsRetrier <- getLooperEnvWith env "STRIPE_EVENTS_RETRIER" $ pure ()
  monetisationEnvMaxItemsFree <- readEnv env "MAX_ITEMS_FREE"
  pure MonetisationEnvironment {..}

getLoopersEnv :: [(String, String)] -> IO LoopersEnvironment
getLoopersEnv env = do
  looperEnvDefaultEnabled <- readEnv env "LOOPERS_DEFAULT_ENABLED"
  looperEnvDefaultPeriod <- readEnv env "LOOPERS_DEFAULT_PERIOD"
  looperEnvDefaultRetryDelay <- readEnv env "LOOPERS_DEFAULT_RETRY_DELAY"
  looperEnvDefaultRetryTimes <- readEnv env "LOOPERS_DEFAULT_RETRY_AMOUNT"
  looperEnvTriggererEnv <- getLooperEnvWith env "TRIGGERER" $ pure ()
  looperEnvEmailerEnv <- getLooperEnvWith env "EMAILER" $ pure ()
  looperEnvTriggeredIntrayItemSchedulerEnv <-
    getLooperEnvWith env "TRIGGERED_INTRAY_ITEM_SCHEDULER" $ pure ()
  looperEnvTriggeredIntrayItemSenderEnv <-
    getLooperEnvWith env "TRIGGERED_INTRAY_ITEM_SENDER" $ pure ()
  looperEnvVerificationEmailConverterEnv <-
    getLooperEnvWith env "VERIFICATION_EMAIL_CONVERTER" $
    getEitherEnv env emailValidateFromString "VERIFICATION_EMAIL_ADDRESS"
  looperEnvTriggeredEmailSchedulerEnv <- getLooperEnvWith env "TRIGGERED_EMAIL_SCHEDULER" $ pure ()
  looperEnvTriggeredEmailConverterEnv <-
    getLooperEnvWith env "TRIGGERED_EMAIL_CONVERTER" $
    getEitherEnv env emailValidateFromString "TRIGGERED_EMAIL_ADDRESS"
  pure LoopersEnvironment {..}

getLooperEnvWith :: [(String, String)] -> String -> IO a -> IO (LooperEnvWith a)
getLooperEnvWith env name func = do
  looperEnvEnable <- readEnv env $ intercalate "_" ["LOOPER", name, "ENABLED"]
  looperEnvPeriod <- readEnv env $ intercalate "_" ["LOOPER", name, "PERIOD"]
  looperEnvRetryPolicy <- getLooperRetryPolicyEnv env name
  looperEnv <- func
  pure LooperEnvWith {..}

getLooperRetryPolicyEnv :: [(String, String)] -> String -> IO LooperEnvRetryPolicy
getLooperRetryPolicyEnv env name = do
  looperEnvRetryDelay <- readEnv env $ intercalate "_" ["LOOPER", name, "RETRY", "DELAY"]
  looperEnvRetryAmount <- readEnv env $ intercalate "_" ["LOOPER", name, "RETRY", "AMOUNT"]
  pure LooperEnvRetryPolicy {..}

getEnv :: [(String, String)] -> String -> Maybe String
getEnv env key = lookup ("TICKLER_SERVER_" <> key) env

readEnv :: Read a => [(String, String)] -> String -> IO (Maybe a)
readEnv env key =
  forM (getEnv env key) $ \s ->
    case readMaybe s of
      Nothing -> die $ unwords ["Un-Read-able value for environment value", key <> ":", s]
      Just val -> pure val

getEitherEnv :: [(String, String)] -> (String -> Either String a) -> String -> IO (Maybe a)
getEitherEnv env func key =
  forM (getEnv env key) $ \s ->
    case func s of
      Left err ->
        die $ unlines [unwords ["Failed to parse environment variable", key <> ":", s], err]
      Right res -> pure res

getArguments :: IO Arguments
getArguments = do
  args <- System.getArgs
  let result = runArgumentsParser args
  handleParseResult result

runArgumentsParser :: [String] -> ParserResult Arguments
runArgumentsParser = execParserPure prefs_ argParser
  where
    prefs_ =
      ParserPrefs
        { prefMultiSuffix = ""
        , prefDisambiguate = True
        , prefShowHelpOnError = True
        , prefShowHelpOnEmpty = True
        , prefBacktrack = True
        , prefColumns = 80
        }

argParser :: ParserInfo Arguments
argParser = info (helper <*> parseArgs) help_
  where
    help_ = fullDesc <> progDesc description
    description = "Tickler server"

parseArgs :: Parser Arguments
parseArgs = Arguments <$> parseCommand <*> parseFlags

parseCommand :: Parser Command
parseCommand = hsubparser $ mconcat [command "serve" parseCommandServe]

parseCommandServe :: ParserInfo Command
parseCommandServe = info parser modifier
  where
    parser = CommandServe <$> parseServeFlags
    modifier = fullDesc <> progDesc "Command example."

parseServeFlags :: Parser ServeFlags
parseServeFlags =
  ServeFlags <$>
  option
    (Just <$> auto)
    (mconcat
       [long "web-host", value Nothing, metavar "HOST", help "the host to serve the web server on"]) <*>
  option
    (Just <$> auto)
    (mconcat [long "api-port", value Nothing, metavar "PORT", help "the port to serve the API on"]) <*>
  option
    (Just <$> str)
    (mconcat
       [ long "database"
       , value Nothing
       , metavar "DATABASE_CONNECTION_STRING"
       , help "The sqlite connection string"
       ]) <*>
  many (strOption (mconcat [long "admin", metavar "USERNAME", help "An admin to use"])) <*>
  parseMonetisationFlags <*>
  parseLooperFlags

parseMonetisationFlags :: Parser MonetisationFlags
parseMonetisationFlags =
  MonetisationFlags <$>
  option
    (Just <$> str)
    (mconcat
       [ long "stripe-plan"
       , value Nothing
       , metavar "PLAN_ID"
       , help "The product pricing plan for stripe"
       ]) <*>
  option
    (Just <$> str)
    (mconcat
       [ long "stripe-secret-key"
       , value Nothing
       , metavar "SECRET_KEY"
       , help "The secret key for stripe"
       ]) <*>
  option
    (Just <$> str)
    (mconcat
       [ long "stripe-publishable-key"
       , value Nothing
       , metavar "PUBLISHABLE_KEY"
       , help "The publishable key for stripe"
       ]) <*>
  parseLooperFlagsWith "stripe-events-fetcher" (pure ()) <*>
  parseLooperFlagsWith "stripe-events-retrier" (pure ()) <*>
  option
    (Just <$> auto)
    (mconcat
       [ long "max-items-free"
       , value Nothing
       , metavar "INT"
       , help "How many items a user can sync in the free plan"
       ])

parseLooperFlags :: Parser LooperFlags
parseLooperFlags =
  LooperFlags <$>
  onOffFlag "loopers" (help $ unwords ["enable or disable all the loopers by default"]) <*>
  option
    (Just <$> auto)
    (mconcat
       [ long "default-period"
       , value Nothing
       , metavar "SECONDS"
       , help "The default period for all loopers"
       ]) <*>
  option
    (Just <$> auto)
    (mconcat
       [ long "default-retry-delay"
       , value Nothing
       , metavar "MICROSECONDS"
       , help "The retry delay for all loopers, in microseconds"
       ]) <*>
  option
    (Just <$> auto)
    (mconcat
       [ long "default-retry-amount"
       , value Nothing
       , metavar "AMOUNT"
       , help "The default amount of times to retry a looper before failing"
       ]) <*>
  parseLooperFlagsWith "triggerer" (pure ()) <*>
  parseLooperFlagsWith "emailer" (pure ()) <*>
  parseLooperFlagsWith "intray-item-scheduler" (pure ()) <*>
  parseLooperFlagsWith "intray-item-sender" (pure ()) <*>
  parseLooperFlagsWith
    "verification-email-converter"
    (option
       (Just <$> eitherReader emailValidateFromString)
       (mconcat
          [ long "verification-email-address"
          , value Nothing
          , metavar "EMAIL_ADDRESS"
          , help "The email address to use to send verification emails from"
          ])) <*>
  parseLooperFlagsWith "triggered-email-scheduler" (pure ()) <*>
  parseLooperFlagsWith
    "triggered-email-converter"
    (option
       (Just <$> eitherReader emailValidateFromString)
       (mconcat
          [ long "triggered-email-address"
          , value Nothing
          , metavar "EMAIL_ADDRESS"
          , help "The email address to use to send triggered item emails from"
          ]))

parseLooperFlagsWith :: String -> Parser a -> Parser (LooperFlagsWith a)
parseLooperFlagsWith name func =
  LooperFlagsWith <$>
  onOffFlag
    (intercalate "-" [name, "looper"])
    (mconcat [help $ unwords ["enable or disable the", name, "looper"]]) <*>
  option
    (Just <$> auto)
    (mconcat
       [ long $ intercalate "-" [name, "period"]
       , value Nothing
       , metavar "SECONDS"
       , help $ unwords ["The period for", name]
       ]) <*>
  parseLooperRetryPolicyFlags name <*>
  func

parseLooperRetryPolicyFlags :: String -> Parser LooperFlagsRetryPolicy
parseLooperRetryPolicyFlags name =
  LooperFlagsRetryPolicy <$>
  option
    (Just <$> auto)
    (mconcat
       [ long $ intercalate "-" [name, "retry-delay"]
       , value Nothing
       , metavar "MICROSECONDS"
       , help $ unwords ["The retry delay for", name]
       ]) <*>
  option
    (Just <$> auto)
    (mconcat
       [ long $ intercalate "-" [name, "retry-amount"]
       , value Nothing
       , metavar "AMOUNT"
       , help $ unwords ["The amount of times to retry for", name]
       ])

onOffFlag :: String -> Mod FlagFields (Maybe Bool) -> Parser (Maybe Bool)
onOffFlag suffix mods =
  flag' (Just True) (mconcat [long $ pf "enable", hidden]) <|>
  flag' (Just False) (mconcat [long $ pf "disable", hidden]) <|>
  flag' Nothing (mconcat [long ("(enable|disable)-" ++ suffix), mods]) <|>
  pure Nothing
  where
    pf s = intercalate "-" [s, suffix]

parseFlags :: Parser Flags
parseFlags = pure Flags
