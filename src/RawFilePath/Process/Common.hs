module RawFilePath.Process.Common (
  Process (..),
  ProcessConf (..),
  proc,
  processStdin,
  processStdout,
  processStderr,
  StreamType,
  mbFd,
  willCreateHandle,
  CreatePipe (..),
  Inherit (..),
  NoStream (..),
  UseHandle (..),
  setStdin,
  setStdout,
  setStderr,
  UnknownStream,
  untypeProcess,
  untypeProcessStdin,
  untypeProcessStdout,
  untypeProcessStderr,
  processStdinUnknown,
  processStdoutUnknown,
  processStderrUnknown,
  PHANDLE,
  ProcessHandle__ (..),
  modifyProcessHandle,
  withProcessHandle,
  fdStdin,
  fdStdout,
  fdStderr,
  mbPipe,
) where

-- extra modules

import qualified GHC.IO.FD as FD
import GHC.IO.Handle.FD as Module (mkHandleFromFD)
import RawFilePath.Import
import System.Posix.Internals (FD)


-- Original declarations

-- | Represents a stream whose creation information is unknown; We don't have
-- any type system guarantee of the t'System.IO.Handle'\'s existence.
--
-- @since 1.1.1
data UnknownStream


-- | The process configuration that is needed for creating new processes. Use
-- 'proc' to make one.
data ProcessConf stdin stdout stderr = ProcessConf
  { cmdargs :: [ByteString]
  -- ^ Executable & arguments, or shell command
  , cwd :: Maybe RawFilePath
  -- ^ Optional path to the working directory for the new process
  , env :: Maybe [(ByteString, ByteString)]
  -- ^ Optional environment (otherwise inherit from the current process)
  , cfgStdin :: stdin
  -- ^ How to determine stdin
  , cfgStdout :: stdout
  -- ^ How to determine stdout
  , cfgStderr :: stderr
  -- ^ How to determine stderr
  , closeFds :: Bool
  -- ^ Close all file descriptors except stdin, stdout and stderr in the new
  -- process
  , createGroup :: Bool
  -- ^ Create a new process group
  , delegateCtlc :: Bool
  -- ^ Delegate control-C handling. Use this for interactive console
  -- processes to let them handle control-C themselves (see below for
  -- details).
  , createNewConsole :: Bool
  -- ^ Use the windows CREATE_NEW_CONSOLE flag when creating the process;
  -- does nothing on other platforms.
  --
  -- Default: @False@
  , newSession :: Bool
  -- ^ Use posix setsid to start the new process in a new session; does nothing on other platforms.
  , childGroup :: Maybe GroupID
  -- ^ Use posix setgid to set child process's group id.
  --
  -- Default: @Nothing@
  , childUser :: Maybe UserID
  -- ^ Use posix setuid to set child process's user id.
  --
  -- Default: @Nothing@
  }


-- | Create a process configuration with the default settings.
proc
  :: RawFilePath
  -- ^ Command to run
  -> [ByteString]
  -- ^ Arguments to the command
  -> ProcessConf Inherit Inherit Inherit
proc cmd args =
  ProcessConf
    { cmdargs = cmd : args
    , cwd = Nothing
    , env = Nothing
    , cfgStdin = Inherit
    , cfgStdout = Inherit
    , cfgStderr = Inherit
    , closeFds = False
    , createGroup = False
    , delegateCtlc = False
    , createNewConsole = False
    , newSession = False
    , childGroup = Nothing
    , childUser = Nothing
    }


-- | Control how the standard input of the process will be initialized.
setStdin
  :: (StreamType newStdin)
  => ProcessConf oldStdin stdout stderr
  -> newStdin
  -> ProcessConf newStdin stdout stderr
setStdin p newStdin = p{cfgStdin = newStdin}


infixl 4 `setStdin`


-- | Control how the standard output of the process will be initialized.
setStdout
  :: (StreamType newStdout)
  => ProcessConf stdin oldStdout stderr
  -> newStdout
  -> ProcessConf stdin newStdout stderr
setStdout p newStdout = p{cfgStdout = newStdout}


infixl 4 `setStdout`


-- | Control how the standard error of the process will be initialized.
setStderr
  :: (StreamType newStderr)
  => ProcessConf stdin stdout oldStderr
  -> newStderr
  -> ProcessConf stdin stdout newStderr
setStderr p newStderr = p{cfgStderr = newStderr}


infixl 4 `setStderr`


-- | The process type. The three type variables denote how its standard
-- streams were initialized.
data Process stdin stdout stderr = Process
  { procStdin :: Maybe Handle
  , procStdout :: Maybe Handle
  , procStderr :: Maybe Handle
  , phandle :: !(MVar ProcessHandle__)
  , mbDelegateCtlc :: !Bool
  , waitpidLock :: !(MVar ())
  }


-- | Take a process and return its standard input handle.
processStdin :: Process CreatePipe stdout stderr -> Handle
processStdin Process{..} = fromMaybe err procStdin
 where
  err = error "This can't happen: stdin is CreatePipe but missing"


-- | Take a process and return its standard output handle.
processStdout :: Process stdin CreatePipe stderr -> Handle
processStdout Process{..} = fromMaybe err procStdout
 where
  err = error "This can't happen: stdout is CreatePipe but missing"


-- | Take a process and return its standard error handle.
processStderr :: Process stdin stdout CreatePipe -> Handle
processStderr Process{..} = fromMaybe err procStderr
 where
  err = error "This can't happen: stderr is CreatePipe but missing"


-- | Create a new pipe for the stream. You get a new t'System.IO.Handle'.
data CreatePipe = CreatePipe deriving (Show)


-- | Inherit the parent (current) process handle. The child will share the
-- stream. For example, if the child writes anything to stdout, it will all go
-- to the parent's stdout.
data Inherit = Inherit deriving (Show)


-- | No stream handle will be passed. Use when you don't want to communicate
-- with a stream. For example, to run something silently.
data NoStream = NoStream deriving (Show)


-- | Use the supplied t'System.IO.Handle'.
data UseHandle = UseHandle Handle deriving (Show)


-- | The class of types that determine the standard stream of a sub-process.
-- You can decide how to initialize the standard streams (stdin, stdout, and
-- stderr) of a sub-process with the instances of this class.
class StreamType c where
  mbFd :: FD -> c -> IO FD
  willCreateHandle :: c -> Bool
  mbFd = undefined
  willCreateHandle = undefined
  {-# MINIMAL #-}


instance StreamType CreatePipe where
  mbFd _ _ = return (-1)
  willCreateHandle _ = True


instance StreamType Inherit where
  mbFd std _ = return std
  willCreateHandle _ = False


instance StreamType NoStream where
  mbFd _ _ = return (-2)
  willCreateHandle _ = False


instance StreamType UseHandle where
  mbFd _std (UseHandle hdl) =
    withHandle "" hdl $ \Handle__{haDevice = dev, ..} -> case cast dev of
      Just fd -> do
        -- clear the O_NONBLOCK flag on this FD, if it is set, since
        -- we're exposing it externally (see #3316 of 'process')
        fd' <- FD.setNonBlockingMode fd False
        return (Handle__{haDevice = fd', ..}, FD.fdFD fd')
      Nothing ->
        ioError $
          mkIOError
            illegalOperationErrorType
            "createProcess"
            (Just hdl)
            Nothing
            `ioeSetErrorString` "handle is not a file descriptor"
  willCreateHandle _ = False


-- Declarations from the process package (modified)

type PHANDLE = CPid


data ProcessHandle__
  = OpenHandle PHANDLE
  | OpenExtHandle PHANDLE PHANDLE PHANDLE
  | ClosedHandle ExitCode


modifyProcessHandle
  :: Process stdin stdout stderr
  -> (ProcessHandle__ -> IO (ProcessHandle__, a))
  -> IO a
modifyProcessHandle p = modifyMVar (phandle p)


withProcessHandle
  :: Process stdin stdout stderr -> (ProcessHandle__ -> IO a) -> IO a
withProcessHandle p = withMVar (phandle p)


fdStdin, fdStdout, fdStderr :: FD
fdStdin = 0
fdStdout = 1
fdStderr = 2


mbPipe :: (StreamType c) => c -> Ptr FD -> IOMode -> IO (Maybe Handle)
mbPipe streamConf pfd mode =
  if willCreateHandle streamConf
    then fmap Just (pfdToHandle pfd mode)
    else return Nothing


-- | Deliberately "un-type" all three type parameters of a process. Then, the
-- three standard streams will be available as 'Maybe' t'System.IO.Handle'.
-- Obtain them using
--
--  * 'processStdinUnknown'
--
--  * 'processStdoutUnknown'
--
--  * 'processStderrUnknown'
--
-- @since 1.1.1
untypeProcess
  :: Process stdin stdout stderr
  -> Process UnknownStream UnknownStream UnknownStream
untypeProcess p = p{phandle = phandle p}


-- | Deliberately "un-type" the standard input stream (stdin) type parameter of
-- a process. After this, use 'processStdinUnknown' to access 'Maybe'
-- t'System.IO.Handle'.
--
-- @since 1.1.1
untypeProcessStdin
  :: Process stdin stdout stderr
  -> Process UnknownStream stdout stderr
untypeProcessStdin p = p{procStdin = procStdin p}


-- | Deliberately "un-type" the standard output stream (stdout) type parameter of
-- a process. After this, use 'processStdinUnknown' to access 'Maybe'
-- t'System.IO.Handle'.
--
-- @since 1.1.1
untypeProcessStdout
  :: Process stdin stdout stderr
  -> Process stdin UnknownStream stderr
untypeProcessStdout p = p{procStdout = procStdout p}


-- | Deliberately "un-type" the standard error stream (stderr) type parameter
-- of a process. After this, use 'processStdinUnknown' to access 'Maybe'
-- t'System.IO.Handle'.
--
-- @since 1.1.1
untypeProcessStderr
  :: Process stdin stdout stderr
  -> Process stdin stdout UnknownStream
untypeProcessStderr p = p{procStderr = procStderr p}


-- | Obtain the stdin t'System.IO.Handle' from a process. The result could be
-- 'Nothing', so dealing with that is the caller's responsibility.
--
-- @since 1.1.1
processStdinUnknown :: Process UnknownStream stdout stderr -> Maybe Handle
processStdinUnknown = procStdin


-- | Obtain the stdout t'System.IO.Handle' from a process. There is no
-- guarantee; It may return 'Nothing', and dealing with it is a runtime
-- responsibility.
--
-- @since 1.1.1
processStdoutUnknown :: Process stdin UnknownStream stderr -> Maybe Handle
processStdoutUnknown = procStdout


-- | Obtain the stderr t'System.IO.Handle' from a process. There is no
-- guarantee; It may return 'Nothing', and dealing with it is a runtime
-- responsibility.
--
-- @since 1.1.1
processStderrUnknown :: Process stdin stdout UnknownStream -> Maybe Handle
processStderrUnknown = procStderr


pfdToHandle :: Ptr FD -> IOMode -> IO Handle
pfdToHandle pfd mode = do
  fd <- peek pfd
  let filepath = "fd:" ++ show fd
  (fD, fd_type) <-
    FD.mkFD
      (fromIntegral fd)
      mode
      (Just (Stream, 0, 0)) -- avoid calling fstat()
      False {-is_socket-}
      False {-non-blocking-}
  fD' <- FD.setNonBlockingMode fD True -- see #3316
  enc <- getLocaleEncoding
  mkHandleFromFD fD' fd_type filepath mode False {-is_socket-} (Just enc)
