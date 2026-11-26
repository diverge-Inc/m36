{-# LANGUAGE PatternSynonyms #-}
-- | A field of a transaction either holds its value or names the earlier transaction which holds it. The second form keeps a transaction from storing (in memory and on disk) what it did not change.
--
-- A reference always names the transaction which holds the value, never a transaction which itself only refers to another one. So resolving a reference is a single lookup, however many transactions have been committed since the value last changed. This is not a convention which callers are asked to follow: a reference can only be made by 'unchangedSince', which takes the marker of the transaction referred to and passes an existing reference on unchanged. 'NotChangedSinceMarker' can be matched on but not applied.
module ProjectM36.ValueMarker
  (ValueMarker(ValueMarker, NotChangedSinceMarker),
   valueIsUpdated,
   emptyValue,
   unchangedSince
  ) where
import ProjectM36.Base
import Control.DeepSeq (NFData(..))

data ValueMarker a = ValueMarker a | Unchanged TransactionId

-- | The value is held by the transaction with this id. For matching only; see 'unchangedSince' for how such a marker is made.
pattern NotChangedSinceMarker :: TransactionId -> ValueMarker a
pattern NotChangedSinceMarker tid <- Unchanged tid

{-# COMPLETE ValueMarker, NotChangedSinceMarker #-}

instance Show a => Show (ValueMarker a) where
  showsPrec d (ValueMarker val) = showParen (d > 10) (showString "ValueMarker " . showsPrec 11 val)
  showsPrec d (Unchanged tid) = showParen (d > 10) (showString "NotChangedSinceMarker " . showsPrec 11 tid)

instance NFData a => NFData (ValueMarker a) where
  rnf (ValueMarker val) = rnf val
  rnf (Unchanged tid) = rnf tid

-- | A reference stays a reference to the same transaction.
instance Functor ValueMarker where
  fmap f (ValueMarker val) = ValueMarker (f val)
  fmap _ (Unchanged tid) = Unchanged tid

-- | The marker of a field for something based on the transaction with the id (a session's workspace, or a later transaction) which has not changed the field. The second argument is the marker which that transaction itself has for the field.
--
-- If the transaction holds the value, the result refers to the transaction. If the transaction refers to an earlier one, the result refers to that same earlier transaction.
unchangedSince :: TransactionId -> ValueMarker a -> ValueMarker a
unchangedSince tid ValueMarker{} = Unchanged tid
unchangedSince _ (Unchanged origin) = Unchanged origin

valueIsUpdated :: ValueMarker a -> Bool
valueIsUpdated ValueMarker{} = True
valueIsUpdated NotChangedSinceMarker{} = False

emptyValue :: Monoid a => ValueMarker a
emptyValue = ValueMarker mempty
