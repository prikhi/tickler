{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DataKinds #-}

module Tickler.Server.Handler.Admin.GetStats
  ( serveAdminGetStats
  ) where

import Import

import Data.Time
import Database.Persist

import Tickler.API

import Tickler.Server.Types

import Tickler.Server.Handler.Stripe
import Tickler.Server.Handler.Utils

serveAdminGetStats :: AuthCookie -> TicklerHandler AdminStats
serveAdminGetStats AuthCookie {..} =
  withAdminCreds authCookieUserUUID $ do
    adminStatsNbUsers <- fromIntegral <$> runDb (count ([] :: [Filter User]))
    adminStatsNbTicklerItems <- fromIntegral <$> runDb (count ([] :: [Filter TicklerItem]))
    adminStatsNbTriggeredItems <- fromIntegral <$> runDb (count ([] :: [Filter TriggeredItem]))
    adminStatsNbSubscribers <-
      do us <- runDb $ selectList [] []
         fmap (fromIntegral . length . catMaybes) $
           forM us $ \(Entity _ u) -> do
             ups <- getUserPaidStatus (userIdentifier u)
             pure $
               case ups of
                 HasNotPaid _ -> Nothing
                 HasPaid t -> Just t
                 NoPaymentNecessary -> Nothing
    now <- liftIO getCurrentTime
    let day :: NominalDiffTime
        day = 86400
    let activeUsers time =
          fmap fromIntegral $ runDb $ count [UserLastLogin >=. Just (addUTCTime (-time) now)]
    activeUsersDaily <- activeUsers day
    activeUsersWeekly <- activeUsers $ 7 * day
    activeUsersMonthly <- activeUsers $ 30 * day
    activeUsersYearly <- activeUsers $ 365 * day
    let adminStatsActiveUsers = ActiveUsers {..}
    pure AdminStats {..}
