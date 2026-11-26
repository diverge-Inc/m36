{-# LANGUAGE DeriveGeneric, DeriveAnyClass #-}
-- | The change of the relation variables of a transaction relative to its first parent.
--
-- Both the Merkle hash of a transaction and its on-disk record are defined over this delta rather than over the complete set of relation variables, so that committing costs time and space proportional to what the transaction changed.
--
-- The delta is canonical: it depends only on the values of the relation variables before and after, not on how the new values were computed. Recomputing it after loading a database yields the delta which was written.
module ProjectM36.RelationVariablesDelta where
import ProjectM36.Base
import ProjectM36.TupleStore
import ProjectM36.PointerEquality
import qualified Data.Map.Strict as M
import qualified Data.Map.Merge.Strict as MM
import qualified Data.HashSet as HS
import GHC.Generics (Generic)
import Control.DeepSeq (NFData)

data RelVarChange =
  -- | The relation variable no longer exists.
  RelVarRemoved |
  -- | The relation variable is now defined by this expression ('DerivedRelVar').
  RelVarExpr GraphRefRelationalExpr |
  -- | The relation variable now holds these tuples ('StoredRelVar'); the atom vectors are in the order of the attributes.
  RelVarFull Attributes [AtomVector] |
  -- | The relation variable holds the tuples of the relation variable of the same name in the first parent plus the first tuples and minus the second tuples.
  RelVarDelta [AtomVector] [AtomVector]
  deriving (Show, Generic, NFData)

-- | Changed relation variables in ascending order of name.
type RelVarsDelta = [(RelVarName, RelVarChange)]

-- | The changes which turn the first relation variables (those of the first parent, or empty for a root transaction) into the second.
relVarsDelta :: RelationVariables -> RelationVariables -> RelVarsDelta
relVarsDelta base new =
  M.toAscList $ MM.merge
    (MM.mapMissing (\_ _ -> RelVarRemoved))
    (MM.mapMissing (\_ rv -> fresh rv))
    (MM.zipWithMaybeMatched (\_ baseRv newRv -> changed baseRv newRv))
    base new
  where
    fresh (StoredRelVar store) = RelVarFull (storeAttributes store) (HS.toList (storeTuples store))
    fresh (DerivedRelVar expr) = RelVarExpr expr
    -- a relation variable which the transaction did not touch is the very same value as in the parent
    changed baseRv newRv | ptrEquals (Forced baseRv) (Forced newRv) = Nothing
    changed (StoredRelVar baseStore) newRv@(StoredRelVar store)
      | attributesVec (storeAttributes baseStore) == attributesVec (storeAttributes store) =
          case storeDiff (storeTuples baseStore) (storeTuples store) of
            ([], []) -> Nothing
            (removed, added) | length removed + length added <= storeSize store -> Just (RelVarDelta added removed)
                             | otherwise -> Just (fresh newRv)
    changed _ newRv@StoredRelVar{} = Just (fresh newRv)
    changed baseRv newRv@(DerivedRelVar newExpr) | baseRv == newRv = Nothing
                                                 | otherwise = Just (RelVarExpr newExpr)

-- | Inverse of 'relVarsDelta': apply the changes to the relation variables of the first parent.
-- Unchanged relation variables are shared with the parent, and changed stores share structure with their previous version.
applyRelVarsDelta :: RelationVariables -> RelVarsDelta -> Either String RelationVariables
applyRelVarsDelta = foldl apply . Right
  where
    apply (Left err) _ = Left err
    apply (Right rvs) (name, change) =
      case change of
        RelVarRemoved -> Right (M.delete name rvs)
        RelVarExpr expr -> Right (M.insert name (DerivedRelVar expr) rvs)
        RelVarFull attrs vecs -> Right (M.insert name (StoredRelVar (storeFromVectors attrs vecs)) rvs)
        RelVarDelta added removed ->
          case M.lookup name rvs of
            Just (StoredRelVar store) ->
              Right (M.insert name (StoredRelVar (storeInsertVectors (storeDeleteVectors store removed) added)) rvs)
            _ -> Left ("relation variable delta without a stored base: " <> show name)
