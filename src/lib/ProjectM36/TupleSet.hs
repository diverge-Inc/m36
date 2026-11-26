module ProjectM36.TupleSet where
import ProjectM36.Base
import ProjectM36.Tuple
import ProjectM36.Error
import qualified Data.HashSet as HS
import qualified Data.Vector as V
import qualified Control.Parallel.Strategies as P
import Data.Either
import Data.Maybe (fromMaybe)
import qualified ProjectM36.TupleStore as TStore

empty :: RelationTupleSet
empty = RelationTupleSet []

emptySingleTuple :: RelationTupleSet
emptySingleTuple = RelationTupleSet [emptyTuple]

--ensure that all maps have the same keys and key count

verifyTupleSet :: Attributes -> RelationTupleSet -> Either RelationalError RelationTupleSet
verifyTupleSet attrs store@(TupleStore storeAttrs _ _ _)
  | attributesVec storeAttrs == attributesVec attrs = pure store -- a store only ever holds verified, distinct tuples
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
    -- a materialized tuple set absorbs the other side without being rebuilt, so that the result shares structure with it
    (TupleStore attrs1 size1 _ _, TupleStore attrs2 size2 _ _)
      | attributesVec attrs1 == attributesVec targetAttrs && attributesVec attrs2 == attributesVec targetAttrs ->
        if size1 >= size2 then into tupSet1 tupSet2 else into tupSet2 tupSet1
    (TupleStore attrs1 _ _ _, _) | attributesVec attrs1 == attributesVec targetAttrs -> into tupSet1 tupSet2
    (_, TupleStore attrs2 _ _ _) | attributesVec attrs2 == attributesVec targetAttrs -> into tupSet2 tupSet1
    _ -> slow
  where
    into store other = fromMaybe slow (TStore.storeInsertTupleSet store other)
    slow = RelationTupleSet $ HS.toList . HS.fromList $ reorder (asList tupSet1) ++ reorder (asList tupSet2)
    reorder = map (reorderTuple targetAttrs)

null :: RelationTupleSet -> Bool
null (RelationTupleSet tups) = Prelude.null tups
