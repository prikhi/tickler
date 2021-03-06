{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}

module Tickler.Server.Looper.Triggerer where

import Import

import Control.Monad.Logger
import Data.Time
import Database.Persist.Sqlite

import Tickler.API

import Tickler.Server.OptParse.Types

import Tickler.Server.Looper.DB
import Tickler.Server.Looper.Types

runTriggerer :: TriggererSettings -> Looper ()
runTriggerer TriggererSettings = do
  logInfoNS "Triggerer" "Starting triggering tickles."
  nowZoned <- liftIO getZonedTime
  let nowLocal = zonedTimeToLocalTime nowZoned
      nowDay = localDay nowLocal
      later = addDays 2 nowDay
  itemsToConsider <-
    runDb $
    selectList
      [TicklerItemScheduledDay <=. later]
      [Asc TicklerItemScheduledDay, Asc TicklerItemScheduledTime]
  mapM_ considerTicklerItem itemsToConsider
  logInfoNS "Triggerer" "Finished triggering tickles."

considerTicklerItem :: Entity TicklerItem -> Looper ()
considerTicklerItem e@(Entity _ ti@TicklerItem {..}) =
  runDb $ do
    now <- liftIO getCurrentTime
    mSets <- getBy $ UniqueUserSettings ticklerItemUserId
    let tz = maybe utc (userSettingsTimeZone . entityVal) mSets
    when (shouldBeTriggered now tz ti) $ triggerTicklerItem now e

triggerTicklerItem :: UTCTime -> Entity TicklerItem -> SqlPersistT IO ()
triggerTicklerItem now (Entity tii ti) = do
  insert_ $ makeTriggeredItem now ti -- Make the triggered item
  case ticklerItemUpdates ti of
    Nothing -> delete tii -- Delete the tickler item
    Just updates -> update tii updates

shouldBeTriggered :: UTCTime -> TimeZone -> TicklerItem -> Bool
shouldBeTriggered now tz ti = localTimeToUTC tz (ticklerItemLocalScheduledTime ti) <= now

ticklerItemLocalScheduledTime :: TicklerItem -> LocalTime
ticklerItemLocalScheduledTime TicklerItem {..} =
  LocalTime ticklerItemScheduledDay $ fromMaybe midnight ticklerItemScheduledTime

makeTriggeredItem :: UTCTime -> TicklerItem -> TriggeredItem
makeTriggeredItem now TicklerItem {..} =
  TriggeredItem
    { triggeredItemIdentifier = ticklerItemIdentifier
    , triggeredItemUserId = ticklerItemUserId
    , triggeredItemType = ticklerItemType
    , triggeredItemContents = ticklerItemContents
    , triggeredItemCreated = ticklerItemCreated
    , triggeredItemScheduledDay = ticklerItemScheduledDay
    , triggeredItemScheduledTime = ticklerItemScheduledTime
    , triggeredItemRecurrence = ticklerItemRecurrence
    , triggeredItemTriggered = now
    }

ticklerItemUpdates :: TicklerItem -> Maybe [Update TicklerItem]
ticklerItemUpdates ti = do
  r <- ticklerItemRecurrence ti
  let (d, mtod) = nextScheduledTime (ticklerItemScheduledDay ti) (ticklerItemScheduledTime ti) r
  pure [TicklerItemScheduledDay =. d, TicklerItemScheduledTime =. mtod]

nextScheduledTime :: Day -> Maybe TimeOfDay -> Recurrence -> (Day, Maybe TimeOfDay)
nextScheduledTime scheduledDay _ r =
  case r of
    EveryDaysAtTime ds mtod -> (addDays (fromIntegral ds) scheduledDay, mtod)
    EveryMonthsOnDay ms md mtod ->
      let clipped = addGregorianMonthsClip (fromIntegral ms) scheduledDay
          day =
            case md of
              Nothing -> clipped
              Just d_ ->
                let (y, m, _) = toGregorian clipped
                 in fromGregorian y m (fromIntegral d_)
       in (day, mtod)
