{-# LANGUAGE JavaScriptFFI     #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes        #-}

module Nauva.Client
    ( Config(..)
    , runClient
    ) where


import           Data.Default
import           Data.Text               (Text)
import qualified Data.Text               as T
import qualified Data.Text.Encoding      as T
import qualified Data.Text.Lazy.Encoding as LT
import qualified Data.Aeson              as A
import qualified Data.Aeson.Types        as A
import           Data.Map                (Map)
import qualified Data.Map                as M
import           Data.Tagged
import qualified Data.ByteString.Lazy    as LBS
import           Data.Monoid
import           Data.Maybe

import           Control.Concurrent
import           Control.Concurrent.STM
import           Control.Monad
import           Control.Monad.Except
import           Control.Monad.Writer.Lazy

import           System.IO.Unsafe

import           Nauva.Handle
import           Nauva.Internal.Events
import           Nauva.Internal.Types
import           Nauva.DOM
import           Nauva.NJS
import           Nauva.NJS.Language
import           Nauva.NJS.Eval
import           Nauva.Native.Bridge
import           Nauva.CSS.Types
import           Nauva.Service.Router

import           GHCJS.Types
import           GHCJS.Marshal
import           GHCJS.Foreign
import           GHCJS.Foreign.Callback
import           Data.JSString.Text
import qualified Data.JSString              as JSS

import           GHCJS.DOM
import           GHCJS.DOM.Document
import qualified GHCJS.DOM.Types            as GHCJSDOMT

import qualified JavaScript.Object          as O
import qualified JavaScript.Object.Internal as O
import           JavaScript.Array.Internal  (fromList)

import           Unsafe.Coerce
import           Debug.Trace



data Config = Config
    { cElement :: RouterH -> Element
      -- ^ The root elment of the application. This will be rendered into the
      -- Handle once.
    }


data Handle = Handle
    { nauvaH :: Nauva.Handle.Handle
    }


runClient :: Config -> IO ()
runClient c = do
    Just document <- currentDocument
    appEl <- getElementByIdUnsafe document ("app" :: JSString)

    nauvaH <- newHandle
    refsVar <- newTVarIO (M.empty :: Map (ComponentId, RefKey) JSVal)

    routerH <- do
        var <- newTVarIO (Location "/")
        chan <- newTChanIO

        pure $ RouterH
            { hLocation = (var, chan)
            , hPush = \url -> do
                putStrLn $ "Router hPush: " <> T.unpack url

                atomically $ do
                    writeTVar var (Location url)
                    writeTChan chan (Location url)

                processSignals nauvaH
            }

    render nauvaH (cElement c routerH)

    locationSignalCopy <- atomically $ dupTChan (snd $ hLocation routerH)
    void $ forkIO $ forever $ do
        path <- atomically $ do
            Location path <- readTChan locationSignalCopy
            pure path

        print path


    bridge <- newBridge appEl $ Impl
        { componentEventImpl = \path fid val -> void $ dispatchComponentEventHandler nauvaH refsVar path fid val
        , nodeEventImpl = \path fid val -> void $ dispatchNodeEventHandler nauvaH refsVar path fid val
        , attachRefImpl = \path val -> void $ attachRefHandler nauvaH refsVar path val
        , detachRefImpl = \path -> void $ detachRefHandler nauvaH refsVar path
        , componentDidMountImpl = \path -> void $ componentDidMountHandler nauvaH path
        , componentWillUnmountImpl = \path -> void $ componentWillUnmountHandler nauvaH path
        }

    changeSignalCopy <- atomically $ dupTChan (changeSignal nauvaH)
    void $ forkIO $ forever $ do
        change <- atomically $ readTChan changeSignalCopy

        case change of
            (ChangeRoot inst) -> do
                spine <- atomically $ do
                    instanceToJSVal inst
                    -- rootInstance <- readTMVar (hInstance nauvaH)
                    -- instanceToJSVal rootInstance

                renderSpine bridge spine
            (ChangeComponent path inst) -> do
                spine <- atomically $ instanceToJSVal inst
                renderSpineAtPath bridge (unPath path) spine

                -- spine <- atomically $ do
                --     rootInstance <- readTMVar (hInstance nauvaH)
                --     instanceToJSVal rootInstance
                -- renderSpine bridge spine


    spine <- atomically $ do
        rootInstance <- readTMVar (hInstance nauvaH)
        instanceToJSVal rootInstance
    renderSpine bridge spine

    pure ()


foreign import javascript unsafe "console.log($1)" js_log :: JSVal -> IO ()


hookHandler :: (forall h. Hooks h -> [F1 () h]) -> Nauva.Handle.Handle -> Path -> IO (Either String ())
hookHandler accessor h path = do
    res <- atomically $ runExceptT $ do
        (mbSCI, inst) <- contextForPath h path
        case mbSCI of
            Nothing -> throwError $ "No Component at path " ++ show (unPath path)
            Just (SomeComponentInstance (ComponentInstance _ component stateRef)) -> do
                state <- lift $ readTMVar stateRef
                let fs = accessor $ componentHooks component

                let rawHookActions = catMaybes $ map (\f -> case evalExp (Context M.empty Nothing Nothing) (f1Fn f UnitE) of
                        Left _ -> Nothing; Right (x, ioa) -> (\v -> (v, ioa)) <$> unsafePerformIO (fromJSVal x)) fs
                forM rawHookActions $ \(rawValue, ioAction) -> do
                    case A.parseEither parseValue (taggedWithHook component rawValue) of
                        Left e -> throwError e
                        Right value -> do
                            actions <- lift $ do
                                state <- takeTMVar stateRef
                                let (newState, actions) = processLifecycleEvent component value (componentState state)
                                newInst <- instantiate $ renderComponent component newState
                                putTMVar stateRef (State newState (componentSignals state) newInst)
                                -- traceShowM path
                                writeTChan (changeSignal h) (ChangeComponent path $ IComponent component stateRef)
                                pure actions

                            pure $ (Effect (ComponentInstance path component stateRef) actions, ioAction)

    case res of
        Left e -> pure $ Left e
        Right effects -> do
            sequence_ $ map snd effects
            executeEffects h (map fst effects)
            pure $ Right ()


componentDidMountHandler :: Nauva.Handle.Handle -> Path -> IO (Either String ())
componentDidMountHandler = hookHandler componentDidMount

componentWillUnmountHandler :: Nauva.Handle.Handle -> Path -> IO (Either String ())
componentWillUnmountHandler = hookHandler componentWillUnmount


refFromAttributes :: [Attribute] -> Maybe Ref
refFromAttributes attrs = case catMaybes (map unRef attrs) of
    ref:_ -> Just ref
    _     -> Nothing
  where
    unRef (AREF x) = Just x
    unRef _        = Nothing


attachRefHandler :: Nauva.Handle.Handle -> TVar (Map (ComponentId, RefKey) JSVal) -> Path -> JSVal -> IO (Either String ())
attachRefHandler h refsVar path jsVal = do
    res <- atomically $ runExceptT $ do
        (mbSCI, inst) <- contextForPath h path
        case (mbSCI, inst) of
            (Just (SomeComponentInstance ci@(ComponentInstance ciPath component stateRef)), INode _ attrs _) -> do
                let mbRef = refFromAttributes attrs
                let mbRefKey = mbRef >>= \(Ref mbRefKey _ _) -> mbRefKey
                case mbRefKey of
                    Nothing -> pure ()
                    Just refKey -> lift $ do
                        modifyTVar refsVar $ M.insert (componentId component, refKey) jsVal

                lift $ case mbRef of
                    Nothing -> Prelude.error "attachRefHandler: no ref on node?!?"
                    Just (Ref _ fra _) -> case evalExp (Context M.empty Nothing (Just jsVal)) (f2Fn fra UnitE (holeE 1)) of
                        Left e -> Prelude.error $ show e
                        Right (jsVal, ioAction) -> case unsafePerformIO (fromJSVal jsVal) of
                            Nothing -> Prelude.error "attachRefHandler: fromJSVal"
                            Just rawValue -> case A.parseEither parseValue (taggedWithAction component rawValue) of
                                Left e -> Prelude.error $ show e
                                Right action -> do
                                    eff <- applyAction h action ci
                                    pure (eff, ioAction)

            _ -> throwError $ "attachRefHandler: " ++ show (unPath path)

    case res of
        Left e -> do
            print e
            pure $ Left e
        Right (effect, ioAction) -> do
            ioAction
            executeEffects h [effect]
            pure $ Right ()


detachRefHandler :: Nauva.Handle.Handle -> TVar (Map (ComponentId, RefKey) JSVal) -> Path -> IO (Either String ())
detachRefHandler h refsVar path = do
    res <- atomically $ runExceptT $ do
        (mbSCI, inst) <- contextForPath h path
        case (mbSCI, inst) of
            (Just (SomeComponentInstance ci@(ComponentInstance ciPath component stateRef)), INode _ attrs _) -> do
                let mbRef = refFromAttributes attrs
                let mbRefKey = mbRef >>= \(Ref mbRefKey _ _) -> mbRefKey
                case mbRefKey of
                    Nothing -> pure ()
                    Just refKey -> lift $ do
                        modifyTVar refsVar $ M.delete (componentId component, refKey)

                lift $ case mbRef of
                    Nothing -> Prelude.error "detachRefHandler: no ref on node?!?"
                    Just (Ref _ _ frd) -> case evalExp (Context M.empty Nothing Nothing) (f1Fn frd UnitE) of
                        Left e -> Prelude.error $ show e
                        Right (jsVal, ioAction) -> case unsafePerformIO (fromJSVal jsVal) of
                            Nothing -> Prelude.error "detachRefHandler: fromJSVal"
                            Just rawValue -> case A.parseEither parseValue (taggedWithAction component rawValue) of
                                Left e -> Prelude.error $ show e
                                Right action -> do
                                    eff <- applyAction h action ci
                                    pure (eff, ioAction)

            _ -> throwError $ "detachRefHandler: " ++ show (unPath path)

    case res of
        Left e -> pure $ Left e
        Right (effect, ioAction) -> do
            ioAction
            executeEffects h [effect]
            pure $ Right ()


dispatchNodeEventHandler :: Nauva.Handle.Handle -> TVar (Map (ComponentId, RefKey) JSVal) -> Path -> FID -> JSVal -> IO (Either String ())
dispatchNodeEventHandler h refsVar path fid ev = do
    res <- atomically $ runExceptT $ do
        (mbSCI, inst) <- contextForPath h path
        case (mbSCI, inst) of
            (Just (SomeComponentInstance ci@(ComponentInstance ciPath component stateRef)), INode tag attrs _) -> do
                let eventListeners = catMaybes $ map (\x -> case x of (AEVL el) -> Just el; _ -> Nothing) attrs
                ctxRefs <- do
                    x <- lift $ readTVar refsVar
                    pure $ M.fromList $ map (\((_,k),v) -> (k,v)) $ M.toList x

                mbRes <- forM eventListeners $ \(EventListener elName fe) -> do
                    if f1Id fe /= fid
                        then pure Nothing
                        else do
                            case evalExp (Context ctxRefs Nothing (Just ev)) (f1Fn fe (holeE 1)) of
                                Left e -> Prelude.error $ show e
                                Right (jsVal, ioAction) -> case unsafePerformIO (fromJSVal jsVal) of
                                    Nothing -> Prelude.error "dispatchNodeEventHandler: fromJSVal"
                                    Just rawValue -> case A.parseEither parseValue (taggedWithAction component rawValue) of
                                        Left e -> Prelude.error $ show e
                                        Right action -> do
                                            effect <- lift $ applyAction h action ci
                                            pure $ Just (effect, ioAction)

                pure $ catMaybes mbRes

            _ -> throwError $ "dispatchNodeEventHandler: " ++ show (unPath path)

    case res of
        Left e -> do
            pure $ Left e
        Right effects -> do
            sequence_ $ map snd effects
            executeEffects h $ map fst effects
            pure $ Right ()



dispatchComponentEventHandler :: Nauva.Handle.Handle -> TVar (Map (ComponentId, RefKey) JSVal) -> Path -> FID -> JSVal -> IO (Either String ())
dispatchComponentEventHandler h refsVar path fid ev = do
    res <- atomically $ runExceptT $ do
        (mbSCI, _) <- contextForPath h path
        case mbSCI of
            Nothing -> throwError $ "dispatchComponentEventHandler: " ++ show (unPath path)
            Just (SomeComponentInstance ci@(ComponentInstance ciPath component stateRef)) -> do
                ctxRefs <- do
                    x <- lift $ readTVar refsVar
                    pure $ M.fromList $ map (\((_,k),v) -> (k,v)) $ M.toList x

                state <- lift $ readTMVar stateRef
                mbRes <- forM (componentEventListeners component $ componentState state) $ \(EventListener elName fe) -> do
                    if f1Id fe /= fid
                        then pure Nothing
                        else do
                            case evalExp (Context ctxRefs Nothing (Just ev)) (f1Fn fe (holeE 1)) of
                                Left e -> Prelude.error $ show e
                                Right (jsVal, ioAction) -> case unsafePerformIO (fromJSVal jsVal) of
                                    Nothing -> Prelude.error "dispatchNodeEventHandler: fromJSVal"
                                    Just rawValue -> case A.parseEither parseValue (taggedWithAction component rawValue) of
                                        Left e -> Prelude.error $ show e
                                        Right action -> do
                                            effect <- lift $ applyAction h action ci
                                            pure $ Just (effect, ioAction)

                pure $ catMaybes mbRes

    case res of
        Left e -> pure $ Left e
        Right effects -> do
            sequence_ $ map snd effects
            executeEffects h $ map fst effects
            pure $ Right ()

foreign import javascript unsafe "$r = $1"
    js_intJSVal :: Int -> JSVal
foreign import javascript unsafe "$r = $1"
    js_doubleJSVal :: Double -> JSVal

foreign import javascript unsafe "true"
    js_true :: JSVal
foreign import javascript unsafe "false"
    js_false :: JSVal

jsCondition :: Condition -> JSVal
jsCondition (CMedia    x) = jsval $ fromList [js_intJSVal 1, jsval $ textToJSString x]
jsCondition (CSupports x) = jsval $ fromList [js_intJSVal 2, jsval $ textToJSString x]

jsCSSRule :: CSSRule -> JSVal
jsCSSRule (CSSStyleRule hash conditions suffixes styleDeclaration) = jsval $ fromList
    [ js_intJSVal 1
    , jsval $ textToJSString $ unHash hash
    , jsval $ fromList $ map jsCondition conditions
    , jsval $ fromList $ map (jsval . JSS.pack . T.unpack . unSuffix) suffixes
    , unsafePerformIO $ do
        o <- O.create

        forM_ styleDeclaration $ \(k, v) -> do
            O.setProp (JSS.pack $ T.unpack k) (jsval $ JSS.pack $ T.unpack $ unCSSValue v) o

        pure $ jsval o
    ]
jsCSSRule (CSSFontFaceRule hash styleDeclaration) = jsval $ fromList
    [ js_intJSVal 5
    , jsval $ textToJSString $ unHash hash
    , unsafePerformIO $ do
        o <- O.create

        forM_ styleDeclaration $ \(k, v) -> do
            O.setProp (JSS.pack $ T.unpack k) (jsval $ JSS.pack $ T.unpack $ unCSSValue v) o

        pure $ jsval o
    ]


instanceToJSVal :: Instance -> STM JSVal
instanceToJSVal = go []
  where
    go :: [Key] -> Instance -> STM JSVal
    go path inst = case inst of
        (IText text) -> pure $ jsval $ textToJSString text

        (INode tag attrs children) -> do
            newChildren <- forM children $ \(key, childI) -> do
                newChild <- instanceToJSVal childI
                key' <- case key of
                    (KIndex  i) -> pure $ js_intJSVal i
                    (KString s) -> pure $ (jsval $ textToJSString s)

                pure $ jsval $ fromList [key', newChild]


            pure $ unsafePerformIO $ do
                o <- O.create

                attributes' <- pure $ jsval $ fromList $ flip map attrs $ \x -> case x of
                    AVAL an (AVBool b)        -> jsval $ fromList [jsval $ textToJSString "AVAL", jsval $ textToJSString an, if b then js_true else js_false]
                    AVAL an (AVString s)      -> jsval $ fromList [jsval $ textToJSString "AVAL", jsval $ textToJSString an, jsval $ textToJSString s]
                    AVAL an (AVInt i)         -> jsval $ fromList [jsval $ textToJSString "AVAL", jsval $ textToJSString an, js_intJSVal i]

                    AEVL (EventListener n fe) -> jsval $ fromList [jsval $ textToJSString "AEVL", js_intJSVal $ unFID $ f1Id fe, jsval $ textToJSString n]

                    ASTY style                -> jsval $ fromList
                        [ jsval $ textToJSString "ASTY"
                        , jsval $ fromList $ map jsCSSRule (unStyle style)
                        ]

                    AREF (Ref mbRefKey fra frd) -> unsafePerformIO $ do
                        o <- O.create

                        case mbRefKey of
                            Nothing -> pure ()
                            Just (RefKey k) -> O.setProp "key" (js_intJSVal $ k) o

                        O.setProp "attach" (js_intJSVal $ unFID $ f2Id fra) o
                        O.setProp "detach" (js_intJSVal $ unFID $ f1Id frd) o

                        pure $ jsval $ fromList [jsval $ textToJSString "AREF", jsval o]

                O.setProp "type" (jsval ("Node" :: JSString)) o
                O.setProp "tag" (jsval $ textToJSString $ unTag tag) o
                O.setProp "attributes" attributes' o
                O.setProp "children" (jsval $ fromList newChildren) o

                pure $ jsval o

        (IThunk _ _ childI) ->
            instanceToJSVal childI

        (IComponent component stateRef) -> do
            state <- readTMVar stateRef
            spine <- instanceToJSVal $ componentInstance state

            eventListeners' <- pure $ jsval $ fromList $ flip map (componentEventListeners component (componentState state)) $ \el -> case el of
                (EventListener n fe) -> jsval $ fromList [js_intJSVal $ unFID $ f1Id fe, jsval $ textToJSString n]

            pure $ unsafePerformIO $ do
                o <- O.create

                hooks <- O.create
                O.setProp "componentDidMount" (jsval $ fromList []) hooks
                O.setProp "componentWillUnmount" (jsval $ fromList []) hooks

                O.setProp "type" (jsval ("Component" :: JSString)) o
                O.setProp "id" (js_intJSVal $ unComponentId $ componentId component) o
                O.setProp "eventListeners" eventListeners' o
                O.setProp "hooks" (jsval hooks) o
                O.setProp "spine" spine o

                pure $ jsval o
