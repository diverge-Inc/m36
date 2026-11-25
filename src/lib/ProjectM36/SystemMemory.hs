#if defined(mingw32_HOST_OS) || defined(darwin_HOST_OS)
{-# LANGUAGE ForeignFunctionInterface #-}
#endif
module ProjectM36.SystemMemory where
import Data.Int (Int64)
#if defined(darwin_HOST_OS)
import Foreign.C.Types (CInt(..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek)
import Text.Megaparsec
import Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer as L
import Data.Void
#endif
#if defined(linux_HOST_OS)
import System.Linux.Proc.MemInfo
import System.Linux.Proc.Errors
import qualified Data.Text as T
import Text.Megaparsec
import Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer as L
import Data.Void
#endif

-- keep the parsers separate and compiling on all platforms so that we can test the parsers without waiting on macos CI runs
-- The darwin implementation now reads sysctl directly (cbits/darwin_memory.c); these parsers are kept for the tests.
-- | Parse memory_pressure output to extract free pages and total memory.
parseMemoryPressureFreeMem :: Parsec Void String MemoryStats
parseMemoryPressureFreeMem = do
  _ <- manyTill anySingle (try (string "The system has "))
  totalMemBytes <- L.decimal
  _ <- manyTill anySingle (try (string "Pages free:"))
  space1
  -- parse integer pages
  freePages <- L.decimal
  pure (freePages * 4096, totalMemBytes) -- 4096 default page size on macOS

-- | Parse memory_pressure output to extract memory pressure percentage.
parseMemoryPressureValue :: Parsec Void String Double
parseMemoryPressureValue = do
  _ <- manyTill anySingle (try (string "System-wide memory free percentage:"))
  space1
  -- parse integer percentage
  n <- L.decimal
  _ <- char '%'
  pure n
  
#if defined(mingw32_HOST_OS)
import Foreign
import Foreign.C.Types
import Foreign.Marshal.Alloc
import Foreign.Marshal.Array
import Foreign.Storable
import System.Win32.Types
import System.Win32.Memory

-- Define the MEMORYSTATUSEX structure
data MEMORYSTATUSEX = MEMORYSTATUSEX
    { dwLength       :: DWORD
    , dwMemoryLoad   :: DWORD
    , ullTotalPhys   :: DWORD64
    , ullAvailPhys   :: DWORD64
    , ullTotalPageFile :: DWORD64
    , ullAvailPageFile :: DWORD64
    , ullTotalVirtual :: DWORD64
    , ullAvailVirtual :: DWORD64
    , ullExtendedVirtual :: DWORD64
    }

-- Foreign function interface to call GlobalMemoryStatusEx
foreign import ccall "GlobalMemoryStatusEx" c_GlobalMemoryStatusEx :: Ptr MEMORYSTATUSEX -> IO ()
#endif

#if defined(darwin_HOST_OS)
-- see cbits/darwin_memory.c
foreign import ccall unsafe "pm36DarwinMemoryStats"
  c_pm36DarwinMemoryStats :: Ptr Int64 -> Ptr Int64 -> IO CInt

foreign import ccall unsafe "pm36DarwinMemoryFreePercentage"
  c_pm36DarwinMemoryFreePercentage :: IO CInt
#endif

type FreeMemBytes = Int64
type TotalMemBytes = Int64
type MemoryStats = (FreeMemBytes, TotalMemBytes)

-- | Get total physical memory in a platform-specific way.
getMemoryStats :: IO (Either String MemoryStats)
getMemoryStats = do
#if defined(mingw32_HOST_OS)
    allocaBytes (sizeOf (undefined :: MEMORYSTATUSEX)) $ \ptr -> do
        let memStatus = MEMORYSTATUSEX { dwLength = fromIntegral (sizeOf (undefined :: MEMORYSTATUSEX)), .. }
        poke ptr memStatus
        c_GlobalMemoryStatusEx ptr
        memStatus' <- peek ptr
        return $ Right (fromIntegral (ullAvailPhys memStatus'), fromIntegral (ullTotalPhys memStatus'))
#elif defined(darwin_HOST_OS)
  alloca $ \freePtr ->
    alloca $ \totalPtr -> do
      ret <- c_pm36DarwinMemoryStats freePtr totalPtr
      if ret /= 0
        then pure (Left "sysctl: failed to read hw.memsize, vm.page_free_count or vm.pagesize")
        else do
          freeBytes <- peek freePtr
          totalBytes <- peek totalPtr
          pure (Right (freeBytes, totalBytes))
#elif defined(linux_HOST_OS)
  eMemInfo <- readProcMemInfo
  pure $ case eMemInfo of
    Left err -> Left (T.unpack (renderProcError err))
    Right memInfo -> Right (fromIntegral (memFree memInfo), fromIntegral (memTotal memInfo))
#endif

-- | Estimate the memory pressure as a number between 0 and 1 which is a ratio of free to actively used memory.
getMemoryPressure :: IO (Maybe Double)
getMemoryPressure = do
#if defined(mingw32_HOST_OS)
  allocaBytes (sizeOf (undefined :: MEMORYSTATUSEX)) $ \ptr -> do
    let memStatus = MEMORYSTATUSEX { dwLength = fromIntegral (sizeOf (undefined :: MEMORYSTATUSEX)), .. }
    poke ptr memStatus
    c_GlobalMemoryStatusEx ptr
    memStatus' <- peek ptr
    return $ Just (fromIntegral (ullAvailPhys memStatus') / fromIntegral (ullTotalPhys memStatus'))
#elif defined(darwin_HOST_OS)
  percentage <- c_pm36DarwinMemoryFreePercentage
  pure $ if percentage < 0
           then Nothing
           else Just (fromIntegral percentage / 100.0)
#elif defined(linux_HOST_OS)
  eMemInfo <- readProcMemInfo
  pure $ case eMemInfo of
    Left _err -> Nothing
    Right memInfo -> Just (fromIntegral (memFree memInfo))
#else
#error Failed to determine matching OS.
#endif

-- on linux, /proc/pressure/(memory/cpu/io) track metrics for determining if useful work is being delayed due to pressure on those subsystems- however we want to prevent getting to this state at all, so it's not that useful

