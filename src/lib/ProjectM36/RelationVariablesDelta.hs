{-# LANGUAGE DeriveGeneric, DeriveAnyClass, BangPatterns #-}
-- | The change of the relation variables of a transaction relative to its first parent.
--
-- Both the Merkle hash of a transaction and its on-disk record are defined over this delta rather than over the complete set of relation variables, so that committing costs time and space proportional to what the transaction changed.
--
-- The delta is canonical: it depends only on the values of the relation variables before and after, not on how the new values were computed. Recomputing it after loading a database yields the delta which was written.
module ProjectM36.RelationVariablesDelta where
import ProjectM36.Base
import ProjectM36.TupleStore
import qualified Data.Map as M
import qualified Data.Map.Merge.Strict as MM
import qualified Data.HashSet as HS
import GHC.Generics (Generic)
import Control.DeepSeq (NFData)

data RelVarChange =
  -- | The relation variable no longer exists.
  RelVarRemoved |
  -- | The relation variable is now defined by this expression (it is not a materialized relation).
  RelVarExpr GraphRefRelationalExpr |
  -- | The relation variable is now this materialized relation; the atom vectors are in the order of the attributes.
  RelVarFull Attributes [AtomVector] |
  -- | The relation variable is the materialized relation of the same name in the first parent plus the first tuples and minus the second tuples.
  RelVarDelta [AtomVector] [AtomVector]
  deriving (Show, Generic, NFData)

-- | Changed relation variables in ascending order of name.
type RelVarsDelta = [(RelVarName, RelVarChange)]

-- | The changes which turn the first relation variables (those of the first parent, or empty for a root transaction) into the second.
relVarsDelta :: RelationVariables -> RelationVariables -> RelVarsDelta
relVarsDelta base new =
  M.toAscList $ MM.merge
    (MM.mapMissing (\_ _ -> RelVarRemoved))
    (MM.mapMissing (\_ expr -> fresh expr))
    (MM.zipWithMaybeMatched (\_ baseExpr newExpr -> changed baseExpr newExpr))
    base new
  where
    fresh (ExistingRelation (Relation _ (TupleStore attrs _ tups _))) = RelVarFull attrs (HS.toList tups)
    fresh expr = RelVarExpr expr
    changed !baseExpr !newExpr | ptrEquals baseExpr newExpr = Nothing
    changed (ExistingRelation (Relation _ (TupleStore baseAttrs _ baseTups _))) newExpr@(ExistingRelation (Relation _ (TupleStore attrs size tups _)))
      | attributesVec baseAttrs == attributesVec attrs =
          case storeDiff baseTups tups of
            ([], []) -> Nothing
            (removed, added) | length removed + length added <= size -> Just (RelVarDelta added removed)
                             | otherwise -> Just (fresh newExpr)
    changed baseExpr newExpr | isMaterializedExpr newExpr = Just (fresh newExpr)
                             | baseExpr == newExpr = Nothing
                             | otherwise = Just (RelVarExpr newExpr)

isMaterializedExpr :: RelationalExprBase a -> Bool
isMaterializedExpr (ExistingRelation (Relation _ TupleStore{})) = True
isMaterializedExpr _ = False

-- | Inverse of 'relVarsDelta': apply the changes to the relation variables of the first parent.
-- Unchanged relation variables are shared with the parent, and changed materialized relations share structure with their previous version.
applyRelVarsDelta :: RelationVariables -> RelVarsDelta -> Either String RelationVariables
applyRelVarsDelta = foldl apply . Right
  where
    apply (Left err) _ = Left err
    apply (Right rvs) (name, change) =
      case change of
        RelVarRemoved -> Right (M.delete name rvs)
        RelVarExpr expr -> Right (M.insert name expr rvs)
        RelVarFull attrs vecs -> Right (M.insert name (ExistingRelation (Relation attrs (storeFromVectors attrs vecs))) rvs)
        RelVarDelta added removed ->
          case M.lookup name rvs of
            Just (ExistingRelation (Relation attrs store@TupleStore{})) ->
              Right (M.insert name (ExistingRelation (Relation attrs (storeInsertVectors (storeDeleteVectors store removed) added))) rvs)
            _ -> Left ("relation variable delta without a materialized base: " <> show name)
