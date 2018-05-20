{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DataKinds #-}

module Tickler.Server.Handler.PostAddIntrayTrigger
    ( servePostAddIntrayTrigger
    ) where

import Import

import Data.Time
import Data.UUID.Typed
import Database.Persist

import Servant hiding (BadPassword, NoSuchUser)
import Servant.Auth.Server as Auth
import Servant.Auth.Server.SetCookieOrphan ()

import Tickler.API

import Tickler.Server.Types

import Tickler.Server.Handler.Utils

servePostAddIntrayTrigger ::
       AuthResult AuthCookie -> AddIntrayTrigger -> TicklerHandler TriggerUUID
servePostAddIntrayTrigger (Authenticated AuthCookie {..}) AddIntrayTrigger {..} = do
    now <- liftIO getCurrentTime
    uuid <- liftIO nextRandomUUID
    undefined
    pure uuid
servePostAddIntrayTrigger _ _ = throwAll err401