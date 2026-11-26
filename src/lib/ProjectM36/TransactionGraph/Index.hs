-- | The transactions of a graph, indexed by their id.
--
-- A set of transactions ordered by id can also find a transaction by its id, but only when it is handed a made-up transaction to compare with, and nothing stops a caller from scanning the set instead. Here the lookup by id is the interface, and the representation is hidden so that every transaction is filed under its own id.
--
-- Meant to be imported qualified.
module ProjectM36.TransactionGraph.Index
  (TransactionIndex,
   empty,
   singleton,
   insert,
   lookup,
   member,
   size,
   ids,
   toList,
   fromList,
   fromSet
  ) where
import Prelude hiding (lookup)
import ProjectM36.Base
import ProjectM36.Transaction.Types
import qualified Data.Map.Strict as M
import qualified Data.Set as S

newtype TransactionIndex = TransactionIndex (M.Map TransactionId Transaction)

empty :: TransactionIndex
empty = TransactionIndex M.empty

singleton :: Transaction -> TransactionIndex
singleton trans = TransactionIndex (M.singleton (transactionId trans) trans)

-- | Add the transaction, replacing a transaction with the same id.
insert :: Transaction -> TransactionIndex -> TransactionIndex
insert trans (TransactionIndex m) = TransactionIndex (M.insert (transactionId trans) trans m)

-- | Logarithmic in the number of transactions.
lookup :: TransactionId -> TransactionIndex -> Maybe Transaction
lookup tid (TransactionIndex m) = M.lookup tid m

member :: TransactionId -> TransactionIndex -> Bool
member tid (TransactionIndex m) = M.member tid m

size :: TransactionIndex -> Int
size (TransactionIndex m) = M.size m

ids :: TransactionIndex -> S.Set TransactionId
ids (TransactionIndex m) = M.keysSet m

-- | All transactions in ascending order of their id. Linear in the number of transactions: for display, validation, and rewriting the whole graph, not for finding a transaction.
toList :: TransactionIndex -> [Transaction]
toList (TransactionIndex m) = M.elems m

fromList :: [Transaction] -> TransactionIndex
fromList = foldr insert empty

fromSet :: S.Set Transaction -> TransactionIndex
fromSet transSet = TransactionIndex (M.fromDistinctAscList [(transactionId trans, trans) | trans <- S.toAscList transSet])
