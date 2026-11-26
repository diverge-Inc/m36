{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE CPP #-}
#ifdef PM36_HASKELL_SCRIPTING
{-# LANGUAGE TypeApplications #-}
#endif
module ProjectM36.Transaction.Persist where
import ProjectM36.RelationVariablesDelta
import ProjectM36.Base
import ProjectM36.Error
import ProjectM36.Transaction.Types
import ProjectM36.ValueMarker
import ProjectM36.DatabaseContext.Types
import ProjectM36.IsomorphicSchema.Types hiding (concreteDatabaseContext, subschemas)
import ProjectM36.DatabaseContextFunctions.Basic
import ProjectM36.Function
import ProjectM36.AccessControlList
import qualified Data.HashSet as HS
import System.FilePath
import qualified Data.Text as T
import ProjectM36.ScriptSession
import ProjectM36.AtomFunctions.Basic (precompiledAtomFunctions)
import Codec.Winery
import GHC.Generics
import Data.Default

#ifdef PM36_HASKELL_SCRIPTING
import GHC
import Control.Exception
import GHC.Paths
import ProjectM36.AtomFunction
#endif

-- | where compiled modules are stored within the database directory
objectFilesPath :: FilePath -> FilePath
objectFilesPath dbdir = dbdir </> "compiled_modules"

-- | What is stored for a function: its type, name, script (for scripted functions), and object file (for functions loaded from a compiled module). Built-in functions carry neither and are found by name when loaded.
type FunctionRecord = ([AtomType], FunctionName, Maybe FunctionBodyScript, Maybe ObjectFileInfo)

-- | The stored form of a transaction. Like 'DatabaseContext', each part is either a value or the id of the earlier transaction since which it has not changed.
-- The relation variables are the exception: they are stored as the change relative to the first parent ('RelVarsDelta'), so that a transaction which inserts a few tuples into a large relation variable is stored in space proportional to the inserted tuples.
data TransactionRecord = TransactionRecord {
  trId :: TransactionId,
  trInfo :: TransactionInfo,
  trRelationVariables :: Either TransactionId RelVarsDelta,
  trInclusionDependencies :: Either TransactionId InclusionDependencies,
  trAtomFunctions :: Either TransactionId [FunctionRecord],
  trDbcFunctions :: Either TransactionId [FunctionRecord],
  trNotifications :: Either TransactionId Notifications,
  trTypeConstructorMapping :: Either TransactionId TypeConstructorMapping,
  trRegisteredQueries :: Either TransactionId RegisteredQueries,
  trAcl :: Either TransactionId DatabaseContextACL,
  trSubschemas :: Either TransactionId Subschemas
  }
  deriving Generic
  deriving Serialise via WineryRecord TransactionRecord

deriving via WineryVariant RelVarChange instance Serialise RelVarChange

-- | Convert a transaction to its stored form. The first argument is the relation variables of the transaction's first parent (empty for a root transaction).
transactionToRecord :: RelationVariables -> Transaction -> TransactionRecord
transactionToRecord baseRelVars trans =
  TransactionRecord {
    trId = transactionId trans,
    trInfo = transactionInfo trans,
    trRelationVariables = relVarsDelta baseRelVars <$> marker (relationVariables context),
    trInclusionDependencies = marker (inclusionDependencies context),
    trAtomFunctions = functionRecords . HS.toList <$> marker (atomFunctions context),
    trDbcFunctions = functionRecords . HS.toList <$> marker (dbcFunctions context),
    trNotifications = marker (notifications context),
    trTypeConstructorMapping = marker (typeConstructorMapping context),
    trRegisteredQueries = marker (registeredQueries context),
    trAcl = marker (acl context),
    trSubschemas = marker (subschemas trans)
    }
  where
    context = concreteDatabaseContext trans
    marker :: ValueMarker a -> Either TransactionId a
    marker (ValueMarker val) = Right val
    marker (NotChangedSinceMarker tid) = Left tid

-- | Rebuild a transaction from its stored form. The first argument is the database directory (to find compiled modules) and the third is the relation variables of the transaction's first parent.
recordToTransaction :: FilePath -> Maybe ScriptSession -> RelationVariables -> TransactionRecord -> IO (Either PersistenceError Transaction)
recordToTransaction dbdir mScriptSession baseRelVars record = do
  let objFilesDir = objectFilesPath dbdir
      marker :: Either TransactionId a -> ValueMarker a
      marker = either NotChangedSinceMarker ValueMarker
      loadMarker :: Default acl => HS.HashSet (Function a acl) -> Either TransactionId [FunctionRecord] -> IO (ValueMarker (HS.HashSet (Function a acl)))
      loadMarker _ (Left tid) = pure (NotChangedSinceMarker tid)
      loadMarker precompiled (Right funcRecords) = ValueMarker <$> loadFuncs objFilesDir precompiled mScriptSession funcRecords
  case traverse (applyRelVarsDelta baseRelVars) (trRelationVariables record) of
    Left err -> pure (Left (CorruptTransactionError (trId record) err))
    Right relvars -> do
      atomFuncs <- loadMarker precompiledAtomFunctions (trAtomFunctions record)
      dbcFuncs <- loadMarker basicDatabaseContextFunctions (trDbcFunctions record)
      let context = DatabaseContext { inclusionDependencies = marker (trInclusionDependencies record),
                                      relationVariables = marker relvars,
                                      typeConstructorMapping = marker (trTypeConstructorMapping record),
                                      notifications = marker (trNotifications record),
                                      atomFunctions = atomFuncs,
                                      dbcFunctions = dbcFuncs,
                                      registeredQueries = marker (trRegisteredQueries record),
                                      acl = marker (trAcl record) }
      pure (Right (Transaction (trId record) (trInfo record) (Schemas context (marker (trSubschemas record)))))

functionRecords :: [Function a acl] -> [FunctionRecord]
functionRecords = map functionData
  where
    functionData f = (funcType f, funcName f, functionScript f, objInfo f)
    objInfo f =
      case funcBody f of
        FunctionObjectLoadedBody objPath modName entryFunc _ ->
          Just (ObjectFileInfo (objPath, modName, entryFunc))
        FunctionScriptBody{} -> Nothing
        FunctionBuiltInBody{} -> Nothing

loadFuncs :: Default acl => FilePath -> HS.HashSet (Function a acl) -> Maybe ScriptSession -> [FunctionRecord] -> IO (HS.HashSet (Function a acl))
loadFuncs objFilesDir precompiledFunctions mScriptSession funcRecords = do
  --we always return the pre-compiled functions
  --load object files and functions in objects (shared libraries or flat object files)
  funcs <- mapM (\(funcType', funcName', mFuncScript, mObjInfo) -> 
                    loadFunc objFilesDir precompiledFunctions mScriptSession funcName' funcType' mFuncScript mObjInfo) funcRecords
  pure (HS.union precompiledFunctions (HS.fromList funcs))

newtype ObjectFileInfo = ObjectFileInfo { _unFileInfo :: (FilePath, String, String) }
 deriving (Show, Serialise)
-- deriving Serialise via WineryVariant ObjectFileInfo

loadFunc :: Default acl => FilePath -> HS.HashSet (Function a acl) -> Maybe ScriptSession -> FunctionName -> [AtomType] -> Maybe FunctionBodyScript -> Maybe ObjectFileInfo -> IO (Function a acl)
loadFunc objFilesDir precompiledFuncs _mScriptSession funcName' _funcType mFuncScript mObjInfo = do
  case mObjInfo of
    --load from shared or static object library
    Just (ObjectFileInfo (path, modName, entryFunc)) -> do
      eFuncs <- loadFunctions modName entryFunc (Just objFilesDir) path
      case eFuncs of
        Left _ -> error $ "Failed to load " <> path
        Right funcs -> 
          case filter (\f -> funcName f == funcName'
                      ) funcs of
            [f] -> pure f
            [] -> error $ "Failed to find function \"" <> T.unpack funcName' <> "\" in " <> path
            _ -> error $ "impossible error in loading \"" <> T.unpack funcName' <> "\""
    Nothing -> 
      case mFuncScript of
        --handle pre-compiled case- pull it from the precompiled list
        Nothing -> case functionForName funcName' precompiledFuncs of
          --WARNING: possible landmine here if we remove a precompiled atom function in the future, then the transaction cannot be restored
          Left _ -> error ("expected precompiled atom function: " ++ T.unpack funcName')
          Right realFunc -> pure realFunc
        --handle a real Haskell scripted function- compile and load
        Just _funcScript ->
#ifdef PM36_HASKELL_SCRIPTING
          case _mScriptSession of
            Nothing -> error "attempted to read serialized AtomFunction without scripting enabled"
            Just scriptSession -> do
              --risk of GHC exception during compilation here
              eCompiledScript <- runGhc (Just libdir) $ do
                setSession (hscEnv scriptSession)
                compileScript (atomFunctionBodyType scriptSession) _funcScript
              case eCompiledScript of
                Left err -> throwIO err
                Right compiledScript -> pure Function { funcName = funcName',
                                                        funcType = _funcType,
                                                        funcBody = FunctionScriptBody _funcScript compiledScript,
                                                        funcACL = def}
#else
         error "Haskell scripting is disabled"
#endif                                    

