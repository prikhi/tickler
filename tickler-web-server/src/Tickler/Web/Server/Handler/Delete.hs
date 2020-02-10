{-# LANGUAGE OverloadedStrings #-}

module Tickler.Web.Server.Handler.Delete
  ( postDeleteTickleR
  , postDeleteTriggeredR
  ) where

import Import

import Yesod

import Tickler.API
import Tickler.Client

import Tickler.Web.Server.Foundation

deleteItemForm :: FormInput Handler ItemUUID
deleteItemForm = ireq hiddenField "item"

postDeleteTriggeredR :: Handler Html
postDeleteTriggeredR =
  withLogin $ \t -> do
    uuid <- runInputPost deleteItemForm
    void $ runClientOrErr $ clientDeleteItem t uuid
    redirect TriggeredsR

postDeleteTickleR :: Handler Html
postDeleteTickleR =
  withLogin $ \t -> do
    uuid <- runInputPost deleteItemForm
    void $ runClientOrErr $ clientDeleteItem t uuid
    redirect TicklesR
