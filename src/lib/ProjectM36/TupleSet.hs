module ProjectM36.TupleSet where
import ProjectM36.Base
import ProjectM36.Tuple
import ProjectM36.Error
import qualified Data.HashSet as HS
import qualified Data.Vector as V
import qualified Control.Parallel.Strategies as P
import Data.Either
import qualified ProjectM36.TupleStore as TStore

empty :: RelationTupleSet
empty = RelationTupleSet []

emptySingleTuple :: RelationTupleSet
emptySingleTuple = RelationTupleSet [emptyTuple]

--ensure that all maps have the same keys and key count

verifyTupleSet :: Attributes -> RelationTupleSet -> Either RelationalError RelationTupleSet
verifyTupleSet attrs tupSet@(StoredTuples store)
  | attributesVec (storeAttributes store) == attributesVec attrs = pure tupSet -- a store only ever holds verified, distinct tuples
verifyTupleSet attrs tupleSet = do
  --check that all tuples have the same attributes and that the atom types match
  let tupleList = map (verifyTuple attrs) (asList tupleSet) `P.using` P.parListChunk chunkSize P.r0
      chunkSize = (length . asList) tupleSet `div` 24
  --let tupleList = P.parMap P.rdeepseq (verifyTuple attrs) (HS.toList tupleSet)
  case lefts tupleList of
    x : _ -> Left x
    _ -> pure $ RelationTupleSet $ (HS.toList . HS.fromList) (rights tupleList)

mkTupleSet :: Attributes -> [RelationTuple] -> Either RelationalError RelationTupleSet
mkTupleSet attrs tuples = verifyTupleSet attrs (RelationTupleSet tuples)

mkTupleSetFromList :: Attributes -> [[Atom]] -> Either RelationalError RelationTupleSet
mkTupleSetFromList attrs atomMatrix = mkTupleSet attrs $ map (mkRelationTuple attrs . V.fromList) atomMatrix


-- | Union two tuplesets while reordering their attribute/atom mapping properly.
tupleSetUnion :: Attributes -> RelationTupleSet -> RelationTupleSet -> RelationTupleSet
tupleSetUnion targetAttrs tupSet1 tupSet2 =
  case (tupSet1, tupSet2) of
    -- a store absorbs the other side without being rebuilt, so that the result shares structure with it
    (StoredTuples store1, StoredTuples store2)
      | fits store1 && fits store2 ->
        if storeSize store1 >= storeSize store2 then into store1 tupSet2 else into store2 tupSet1
    (StoredTuples store1, _) | fits store1 -> into store1 tupSet2
    (_, StoredTuples store2) | fits store2 -> into store2 tupSet1
    _ -> slow
  where
    fits store = attributesVec (storeAttributes store) == attributesVec targetAttrs
    into store other = maybe slow StoredTuples (TStore.storeInsertTupleSet store other)
    slow = RelationTupleSet $ HS.toList . HS.fromList $ reorder (asList tupSet1) ++ reorder (asList tupSet2)
    reorder = map (reorderTuple targetAttrs)

null :: RelationTupleSet -> Bool
null (RelationTupleSet tups) = Prelude.null tups
