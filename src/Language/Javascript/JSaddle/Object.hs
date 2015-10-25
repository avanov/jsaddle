{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE ForeignFunctionInterface #-}
#if (defined(ghcjs_HOST_OS) && defined(USE_JAVASCRIPTFFI)) || !defined(USE_WEBKIT)
{-# LANGUAGE JavaScriptFFI #-}
#endif
-----------------------------------------------------------------------------
--
-- Module      :  Language.Javascript.JSaddle.Object
-- Copyright   :  (c) Hamish Mackenzie
-- License     :  MIT
--
-- Maintainer  :  Hamish Mackenzie <Hamish.K.Mackenzie@googlemail.com>
--
-- | Interface to JavaScript object
--
-----------------------------------------------------------------------------

module Language.Javascript.JSaddle.Object (
    Object
  , MakeObject(..)

  -- * Property lookup
  , (!)
  , (!!)
  , js
  , JSF(..)
  , jsf
  , js0
  , js1
  , js2
  , js3
  , js4
  , js5
  , jsg

  -- * Setting the value of a property
  , (<#)

  -- * Calling JavaSctipt
  , (#)
  , new
  , call
  , obj

  -- * Calling Haskell From JavaScript
  , function
  , fun
  , JSCallAsFunction(..)
  -- ** Object Constructors

  -- | There is no good way to support calling haskell code as a JavaScript
  --   constructor for the same reason that the return type of
  --   'JSCallAsFunction' is 'JSUndefined'.
  --
  --   Instead of writing a constructor in Haskell write a function
  --   that takes a continuation.  Create the JavaScript object
  --   and pass it to the continuation.

  -- * Arrays
  , array

  -- * Global Object
  , global

  -- * Enumerating Properties
  , propertyNames

  -- * Low level
  , objCallAsFunction
  , objCallAsConstructor
) where

import Prelude hiding ((!!))
import Language.Javascript.JSaddle.Types
       (JSPropertyNameArrayRef, JSStringRef, Object(..), JSValueRefRef,
        JSValueRef, JSContextRef, Index)
import Foreign.C.Types (CSize(..), CULong(..), CUInt(..), CULLong(..))
#if (defined(ghcjs_HOST_OS) && defined(USE_JAVASCRIPTFFI)) || !defined(USE_WEBKIT)
import GHCJS.Types (nullRef, jsval)
import GHCJS.Foreign.Callback (syncCallback2, OnBlocked(..), Callback)
import GHCJS.Marshal.Pure (pFromJSVal)
import JavaScript.Array (JSArray)
import qualified JavaScript.Array as Array (toListIO, fromListIO)
import JavaScript.Array.Internal (SomeJSArray(..))
import qualified JavaScript.Object as Object (create)
import Control.Monad (liftM)
import Control.Applicative ((<$>))
import Data.Coerce (coerce)
#else
import Graphics.UI.Gtk.WebKit.JavaScriptCore.JSObjectRef
       (jsobjectmake, jspropertynamearraygetnameatindex,
        jspropertynamearraygetcount, jsobjectcopypropertynames,
        jsobjectsetpropertyatindex, jsobjectgetpropertyatindex,
        jsobjectcallasconstructor, jsobjectmakearray,
        jsobjectcallasfunction, jsobjectgetproperty, jsobjectsetproperty,
        JSPropertyAttributes, JSObjectCallAsFunctionCallback,
        jsobjectmakefunctionwithcallback, JSObjectCallAsFunctionCallback')
import Graphics.UI.Gtk.WebKit.JavaScriptCore.JSValueRef
       (jsvaluemakeundefined)
import Graphics.UI.Gtk.WebKit.JavaScriptCore.JSContextRef
       (jscontextgetglobalobject)
import Foreign (peekArray, nullPtr, withArrayLen)
#endif
import Language.Javascript.JSaddle.Exception (rethrow)
import Language.Javascript.JSaddle.Value
       (JSUndefined, valMakeUndefined, valToObject)
import Language.Javascript.JSaddle.PropRef (JSPropRef(..))
import Language.Javascript.JSaddle.Classes
       (MakeValueRef(..), MakeStringRef(..), MakeArgRefs(..), MakePropRef(..),
        MakeObject(..))
import Language.Javascript.JSaddle.Monad
       (JSM)
import Control.Monad.Trans.Reader (runReaderT, ask)
import Control.Monad.IO.Class (MonadIO(..))
import qualified Control.Exception as E (catch)
import Control.Exception (SomeException)
import qualified Data.Text as T (pack)
import Foreign.Storable (Storable(..))
import Language.Javascript.JSaddle.Properties
import Control.Lens
       (IndexPreservingGetter, to, (^.))
import Language.Javascript.JSaddle.String (textToStr)

-- | If we already have a Object we are fine
instance MakeObject Object where
    makeObject = return
    {-# INLINE makeObject #-}

-- | Object can be made by evaluating a function in 'JSM' as long
--   as it returns something we can make into a Object.
instance MakeObject v => MakeObject (JSM v) where
    makeObject v = v >>= makeObject
    {-# INLINE makeObject #-}

-- | Lookup a property based on its name.  This function just constructs a JSPropRef
--   the lookup is delayed until we use the JSPropRef.  This makes it a bit lazy compared
--   to JavaScript's @.@ operator.
--
-- >>> testJSaddle $ eval "'Hello World'.length"
-- >>> testJSaddle $ val "Hello World" ! "length"
-- 11
(!) :: (MakeObject this, MakeStringRef name)
    => this          -- ^ Object to look on
    -> name          -- ^ Name of the property to find
    -> JSM JSPropRef -- ^ Property reference
this ! name = do
    rthis <- makeObject this
    return (JSPropRef rthis rname)
  where
    rname = makeStringRef name
{-# INLINE (!) #-}

-- | Lookup a property based on its index.  This function just constructs a JSPropRef
--   the lookup is delayed until we use the JSPropRef.  This makes it a bit lazy compared
--   to JavaScript's @[]@ operator.
--
-- >>> testJSaddle $ eval "'Hello World'[6]"
-- >>> testJSaddle $ val "Hello World" !! 6
-- W
(!!) :: (MakeObject this)
     => this          -- ^ Object to look on
     -> Index         -- ^ Index of the property to lookup
     -> JSM JSPropRef -- ^ Property reference
this !! index = do
    rthis <- makeObject this
    return (JSPropIndexRef rthis index)
{-# INLINE (!!) #-}

-- | Makes a getter for a particular property name.
--
-- > js name = to (!name)
--
-- >>> testJSaddle $ eval "'Hello World'.length"
-- >>> testJSaddle $ val "Hello World" ^. js "length"
-- 11
js :: (MakeObject s, MakeStringRef name)
   => name          -- ^ Name of the property to find
   -> IndexPreservingGetter s (JSM JSPropRef)
js name = to (!name)
{-# INLINE js #-}

-- | Java script function applications have this type
type JSF = forall o . MakeObject o => IndexPreservingGetter o (JSM JSValueRef)

-- | Handy way to call a function
--
-- > jsf name = js name . to (# args)
--
-- >>> testJSaddle $ val "Hello World" ^. jsf "indexOf" ["World"]
-- 6
jsf :: (MakeStringRef name, MakeArgRefs args) => name -> args -> JSF
jsf name args = function . to (# args)
    where
        function = js name
{-# INLINE jsf #-}

-- | Handy way to call a function that expects no arguments
--
-- > js0 name = jsf name ()
--
-- >>> testJSaddle $ val "Hello World" ^. js0 "toLowerCase"
-- hello world
js0 :: (MakeStringRef name) => name -> JSF
js0 name = jsf name ()
{-# INLINE js0 #-}

-- | Handy way to call a function that expects one argument
--
-- > js1 name a0 = jsf name [a0]
--
-- >>> testJSaddle $ val "Hello World" ^. js1 "indexOf" "World"
-- 6
js1 :: (MakeStringRef name, MakeValueRef a0) => name -> a0 -> JSF
js1 name a0 = jsf name [a0]
{-# INLINE js1 #-}

-- | Handy way to call a function that expects two arguments
js2 :: (MakeStringRef name, MakeValueRef a0, MakeValueRef a1) => name -> a0 -> a1 -> JSF
js2 name a0 a1 = jsf name (a0, a1)
{-# INLINE js2 #-}

-- | Handy way to call a function that expects three arguments
js3 :: (MakeStringRef name, MakeValueRef a0, MakeValueRef a1, MakeValueRef a2)
    => name -> a0 -> a1 -> a2 -> JSF
js3 name a0 a1 a2 = jsf name (a0, a1, a2)
{-# INLINE js3 #-}

-- | Handy way to call a function that expects four arguments
js4 :: (MakeStringRef name, MakeValueRef a0, MakeValueRef a1, MakeValueRef a2,
        MakeValueRef a3)
    => name -> a0 -> a1 -> a2 -> a3 -> JSF
js4 name a0 a1 a2 a3 = jsf name (a0, a1, a2, a3)
{-# INLINE js4 #-}

-- | Handy way to call a function that expects five arguments
js5 :: (MakeStringRef name, MakeValueRef a0, MakeValueRef a1, MakeValueRef a2,
        MakeValueRef a3, MakeValueRef a4)
    => name -> a0 -> a1 -> a2 -> a3 -> a4 -> JSF
js5 name a0 a1 a2 a3 a4 = jsf name (a0, a1, a2, a3, a4)
{-# INLINE js5 #-}


-- | Handy way to get and hold onto a reference top level javascript
--
-- >>> testJSaddle $ eval "w = console; w.log('Hello World')"
-- >>> testJSaddle $ do w <- jsg "console"; w ^. js "log" # ["Hello World"]
-- 11
jsg :: MakeStringRef a => a -> JSM JSPropRef
jsg name = global ! name
{-# INLINE jsg #-}

-- | Call a JavaScript function
--
-- >>> testJSaddle $ eval "'Hello World'.indexOf('World')"
-- >>> testJSaddle $ val "Hello World" ! "indexOf" # ["World"]
-- 6
infixr 2 #
(#) :: (MakePropRef prop, MakeArgRefs args)
    => prop -> args -> JSM JSValueRef
prop # args = do
    rprop <- makePropRef prop
    (this, f) <- objGetProperty' rprop
    f' <- valToObject f
    rethrow $ objCallAsFunction f' this args
{-# INLINE (#) #-}

-- | Call a JavaScript function
--
-- >>> testJSaddle $ eval "var j = {}; j.x = 1; j.x"
-- >>> testJSaddle $ do {j <- eval "({})"; j!"x" <# 1; j!"x"}
-- 1
infixr 0 <#
(<#) :: (MakePropRef prop, MakeValueRef val)
     => prop          -- ^ Property to set
     -> val           -- ^ Value to set it to
     -> JSM JSPropRef -- ^ Reference to the property set
prop <# val = do
    p <- makePropRef prop
    objSetProperty p val
    return p
{-# INLINE (<#) #-}

-- | Use this to create a new JavaScript object
--
-- If you pass more than 7 arguments to a constructor for a built in
-- JavaScript type (like Date) then this function will fail.
--
-- >>> testJSaddle $ new "Date" (2013, 1, 1)
-- Fri Feb 01 2013 00:00:00 GMT+1300 (NZDT)
new :: (MakeObject constructor, MakeArgRefs args)
    => constructor
    -> args
    -> JSM JSValueRef
new constructor args = do
    f <- makeObject constructor
    rethrow $ objCallAsConstructor f args
{-# INLINE new #-}

-- | Call function with a given @this@.  In most cases you should use '#'.
--
-- >>> testJSaddle $ eval "(function(){return this;}).apply('Hello', [])"
-- >>> testJSaddle $ do { test <- eval "(function(){return this;})"; call test (val "Hello") () }
-- Hello
call :: (MakeObject function, MakeObject this, MakeArgRefs args)
    => function -> this -> args -> JSM JSValueRef
call function this args = do
    rfunction <- makeObject function
    rthis     <- makeObject this
    rethrow $ objCallAsFunction rfunction rthis args
{-# INLINE call #-}

-- | Make an empty object using the default constuctor
--
-- >>> testJSaddle $ eval "var a = {}; a.x = 'Hello'; a.x"
-- >>> testJSaddle $ do { a <- obj; a ^. js "x" <# "Hello"; a ^. js "x" }
-- Hello
obj :: JSM Object
#if (defined(ghcjs_HOST_OS) && defined(USE_JAVASCRIPTFFI)) || !defined(USE_WEBKIT)
obj = liftIO Object.create
#else
obj = do
    gctxt <- ask
    liftIO $ Object <$> jsobjectmake gctxt nullPtr nullPtr
#endif
{-# INLINE obj #-}

-- | Type used for Haskell functions called from JavaScript.
type JSCallAsFunction = JSValueRef      -- ^ Function object
                     -> JSValueRef      -- ^ this
                     -> [JSValueRef]    -- ^ Function arguments
                     -> JSM JSUndefined -- ^ Only 'JSUndefined' can be returned because
                                        --   the function may need to be executed in a
                                        --   different thread.  If you need to get a
                                        --   value out pass in a continuation function
                                        --   as an argument and invoke it from haskell.

-- | Short hand @::JSCallAsFunction@ so a haskell function can be passed to
--   a to a JavaScipt one.
--
-- >>> testJSaddle $ eval "(function(f) {f('Hello');})(function (a) {console.log(a)})"
-- >>> testJSaddle $ call (eval "(function(f) {f('Hello');})") global [fun $ \ _ _ args -> valToText (head args) >>= (liftIO . putStrLn . T.unpack) ]
-- Hello
-- undefined
fun :: JSCallAsFunction -> JSCallAsFunction
fun = id
{-# INLINE fun #-}

#if (!defined(ghcjs_HOST_OS) || !defined(USE_JAVASCRIPTFFI)) && defined(USE_WEBKIT)
foreign import ccall "wrapper"
  mkJSObjectCallAsFunctionCallback :: JSObjectCallAsFunctionCallback' -> IO JSObjectCallAsFunctionCallback
#endif

-- ^ Make a JavaScript function object that wraps a Haskell function.
function :: MakeStringRef name
         => name             -- ^ Name of the function
         -> JSCallAsFunction -- ^ Haskell function to call
         -> JSM Object       -- ^ Returns a JavaScript function object that will
                             --   call the Haskell one when it is called
#if defined(ghcjs_HOST_OS) && defined(USE_JAVASCRIPTFFI)
function name f = liftIO $ do
    callback <- syncCallback2 ContinueAsync $ \this args -> do
        rargs <- Array.toListIO (coerce args)
        runReaderT (f this this rargs) () -- TODO pass function object through
    makeFunctionWithCallback (makeStringRef name) callback
foreign import javascript unsafe "$r = function () { $2(this, arguments); }"
    makeFunctionWithCallback :: JSStringRef -> Callback (JSValueRef -> JSValueRef -> IO ()) -> IO Object
#elif defined(USE_WEBKIT)
function name f = do
    gctxt <- ask
    callback <- liftIO $ mkJSObjectCallAsFunctionCallback wrap
    liftIO $ Object <$> jsobjectmakefunctionwithcallback gctxt (makeStringRef name) callback
  where
    wrap ctx fobj this argc argv exception = do
            args <- peekArray (fromIntegral argc) argv
            (`runReaderT` ctx) $
                f fobj this args >>= makeValueRef
      `E.catch` \(e :: SomeException) -> do
            str <- runReaderT (makeValueRef . T.pack $ show e) ctx
            poke exception str
            jsvaluemakeundefined ctx
#else
function  = undefined
#endif

-- | A callback to Haskell can be used as a JavaScript value.  This will create
--   an anonymous JavaScript function object.  Use 'function' to create one with
--   a name.
instance MakeValueRef JSCallAsFunction where
#if (defined(ghcjs_HOST_OS) && defined(USE_JAVASCRIPTFFI)) || !defined(USE_WEBKIT)
    makeValueRef f = jsval <$> function (pFromJSVal nullRef :: JSStringRef) f
#else
    makeValueRef f = function (nullPtr :: JSStringRef) f >>= makeValueRef
#endif
    {-# INLINE makeValueRef #-}

instance MakeArgRefs JSCallAsFunction where
    makeArgRefs f = do
#if (defined(ghcjs_HOST_OS) && defined(USE_JAVASCRIPTFFI)) || !defined(USE_WEBKIT)
        rarg <- jsval <$> function (pFromJSVal nullRef :: JSStringRef) f
#else
        rarg <- function (nullPtr:: JSStringRef) f >>= makeValueRef
#endif
        return [rarg]
    {-# INLINE makeArgRefs #-}

makeArray :: MakeArgRefs args => args -> JSValueRefRef -> JSM Object
#if (defined(ghcjs_HOST_OS) && defined(USE_JAVASCRIPTFFI)) || !defined(USE_WEBKIT)
makeArray args exceptions = do
    rargs <- makeArgRefs args
    liftIO $ Object . jsval <$> Array.fromListIO rargs
#else
makeArray args exceptions = do
    gctxt <- ask
    rargs <- makeArgRefs args
    liftIO $ withArrayLen rargs $ \ len ptr ->
        Object <$> jsobjectmakearray gctxt (fromIntegral len) ptr exceptions
#endif
{-# INLINE makeArray #-}

-- | Make an JavaScript array from a list of values
--
-- >>> testJSaddle $ eval "['Hello', 'World'][1]"
-- >>> testJSaddle $ array ["Hello", "World"] !! 1
-- World
-- >>> testJSaddle $ eval "['Hello', null, undefined, true, 1]"
-- >>> testJSaddle $ array ("Hello", JSNull, (), True, 1.0::Double)
-- Hello,,,true,1
array :: MakeArgRefs args => args -> JSM Object
array = rethrow . makeArray

-- | JavaScript's global object
global :: JSM Object
#if defined(ghcjs_HOST_OS) && defined(USE_JAVASCRIPTFFI)
global = liftIO js_window
{-# INLINE global #-}
foreign import javascript unsafe "$r = window"
    js_window :: IO Object
#elif defined(USE_WEBKIT)
global = ask >>= (liftIO . fmap Object . jscontextgetglobalobject)
{-# INLINE global #-}
#else
global = undefined
#endif

-- | Get an array containing the property names present on a given object
#if (!defined(ghcjs_HOST_OS) || !defined(USE_JAVASCRIPTFFI)) && defined(USE_WEBKIT)
copyPropertyNames :: MakeObject this => this -> JSM JSPropertyNameArrayRef
copyPropertyNames this = do
    gctxt <- ask
    Object rthis <- makeObject this
    liftIO $ jsobjectcopypropertynames gctxt rthis
{-# INLINE copyPropertyNames #-}

-- | Get the number of names in a property name array
propertyNamesCount :: MonadIO m => JSPropertyNameArrayRef -> m CSize
propertyNamesCount names = liftIO $ jspropertynamearraygetcount names
{-# INLINE propertyNamesCount #-}

-- | Get a name out of a property name array
propertyNamesAt :: MonadIO m => JSPropertyNameArrayRef -> CSize -> m JSStringRef
propertyNamesAt names index = liftIO $ jspropertynamearraygetnameatindex names index
{-# INLINE propertyNamesAt #-}

-- | Convert property array to a list
propertyNamesList :: MonadIO m => JSPropertyNameArrayRef -> m [JSStringRef]
propertyNamesList names = do
    count <- propertyNamesCount names
    mapM (propertyNamesAt names) $ enumFromTo 0 (count - 1)
{-# INLINE propertyNamesList #-}
#endif

-- | Get a list containing the property names present on a given object
propertyNames :: MakeObject this => this -> JSM [JSStringRef]
#if defined(ghcjs_HOST_OS) && defined(USE_JAVASCRIPTFFI)
propertyNames this = makeObject this >>= liftIO . js_propertyNames >>= liftIO . (fmap (map pFromJSVal)) . Array.toListIO
{-# INLINE propertyNames #-}
foreign import javascript unsafe "$r = []; h$forIn($1, function(n){$r.push(n);})"
    js_propertyNames :: Object -> IO JSArray
#elif defined(USE_WEBKIT)
propertyNames this = copyPropertyNames this >>= propertyNamesList
{-# INLINE propertyNames #-}
#else
propertyNames = undefined
#endif

-- | Get a list containing references to all the  properties present on a given object
properties :: MakeObject this => this -> JSM [JSPropRef]
properties this = propertyNames this >>= mapM (this !)

-- | Call a JavaScript object as function.  Consider using '#'.
objCallAsFunction :: MakeArgRefs args
                  => Object
                  -> Object
                  -> args
                  -> JSValueRefRef
                  -> JSM JSValueRef
#if defined(ghcjs_HOST_OS) && defined(USE_JAVASCRIPTFFI)
objCallAsFunction function this args exceptions = do
    rargs <- makeArgRefs args >>= liftIO . Array.fromListIO
    liftIO $ js_apply function this rargs exceptions
{-# INLINE objCallAsFunction #-}
foreign import javascript unsafe "try { $r = $1.apply($2, $3) } catch(e) { $4[0] = e }"
    js_apply :: Object -> Object -> JSValueRefRef -> JSValueRefRef -> IO JSValueRef
#elif defined(USE_WEBKIT)
objCallAsFunction (Object function) (Object this) args exceptions = do
    gctxt <- ask
    rargs <- makeArgRefs args
    liftIO $ withArrayLen rargs $ \ largs pargs ->
        jsobjectcallasfunction gctxt function this (fromIntegral largs) pargs exceptions
{-# INLINE objCallAsFunction #-}
#else
objCallAsFunction = undefined
#endif

-- | Call a JavaScript object as a constructor. Consider using 'new'.
--
-- If you pass more than 7 arguments to a constructor for a built in
-- JavaScript type (like Date) then this function will fail.
objCallAsConstructor :: MakeArgRefs args
                     => Object
                     -> args
                     -> JSValueRefRef
                     -> JSM JSValueRef
#if defined(ghcjs_HOST_OS) && defined(USE_JAVASCRIPTFFI)
objCallAsConstructor function args exceptions = do
    rargs <- makeArgRefs args >>= liftIO . Array.fromListIO
    liftIO $ js_new function rargs exceptions
foreign import javascript unsafe "\
    try {\
        switch($2.length) {\
            case 0 : $r = new $1(); break;\
            case 1 : $r = new $1($2[0]); break;\
            case 2 : $r = new $1($2[0],$2[1]); break;\
            case 3 : $r = new $1($2[0],$2[1],$2[2]); break;\
            case 4 : $r = new $1($2[0],$2[1],$2[2],$2[3]); break;\
            case 5 : $r = new $1($2[0],$2[1],$2[2],$2[3],$2[4]); break;\
            case 6 : $r = new $1($2[0],$2[1],$2[2],$2[3],$2[4],$2[5]); break;\
            case 7 : $r = new $1($2[0],$2[1],$2[2],$2[3],$2[4],$2[5],$2[6]); break;\
            default:\
                var ret;\
                var temp = function() {\
                    ret = $1.apply(this, $2);\
                };\
                temp.prototype = $1.prototype;\
                var i = new temp();\
                if(ret instanceof Object)\
                    return ret;\
                i.constructor = $1;\
                return i;\
        }\
    }\
    catch(e) {\
        $3[0] = e;\
    }"
    js_new :: Object -> JSValueRefRef -> JSValueRefRef -> IO JSValueRef
#elif defined(USE_WEBKIT)
objCallAsConstructor (Object function) args exceptions = do
    gctxt <- ask
    rargs <- makeArgRefs args
    liftIO $ withArrayLen rargs $ \ largs pargs ->
        jsobjectcallasconstructor gctxt function (fromIntegral largs) pargs exceptions
#else
objCallAsConstructor = undefined
#endif





