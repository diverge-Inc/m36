module ProjectM36.TransactionGraph.Types where
import ProjectM36.Base
--import ProjectM36.DisconnectedTransaction
import ProjectM36.Transaction.Types
import ProjectM36.TransactionGraph.Index (TransactionIndex)
import qualified ProjectM36.TransactionGraph.Index as TIdx
import qualified Data.Set as S
import qualified Data.Map as M
import qualified Data.List.NonEmpty as NE

transactions :: TransactionGraph -> TransactionIndex
transactions (TransactionGraph _ t) = t

transactionHeads :: TransactionGraph -> TransactionHeads
transactionHeads (TransactionGraph heads _) = heads


type TransactionHeads = M.Map HeadName Transaction

-- | The transaction graph is the global database's state which references every committed transaction.
-- The transactions are held in a 'TransactionIndex', which finds a transaction by its id without a scan.
data TransactionGraph = TransactionGraph TransactionHeads TransactionIndex

type TransactionParents = NE.NonEmpty TransactionId

transactionHeadsForGraph :: TransactionGraph -> TransactionHeads
transactionHeadsForGraph (TransactionGraph hs _) = hs

transactionsForGraph :: TransactionGraph -> TransactionIndex
transactionsForGraph (TransactionGraph _ ts) = ts

-- | All transactions of the graph in ascending order of their id.
transactionListForGraph :: TransactionGraph -> [Transaction]
transactionListForGraph = TIdx.toList . transactionsForGraph

transactionIdsForGraph :: TransactionGraph -> S.Set TransactionId
transactionIdsForGraph = TIdx.ids . transactionsForGraph

-- | Used to track changes to child transactions relative to parent transactions as a write optimization. We can refer to the parent transaction for the data which has already been written, but we need to track then what actually changed.
data TransactionGraphIncrementalWriteInfo =
  TransactionGraphIncrementalWriteInfo {
  uncommittedTransactions :: S.Set UncommittedTransaction, -- the disconnected transaction holds the parent id, but the fst transaction id is the transaction id of the transaction in the "newGraph" which has not yet been flushed to permanent storage
  newGraph :: TransactionGraph
      }

affectedTransactionIds :: TransactionGraphIncrementalWriteInfo -> S.Set TransactionId
affectedTransactionIds winfo = S.map (\(UncommittedTransaction t) -> transactionId t) (uncommittedTransactions winfo)

data MergeHeadNames = MergeHeadNames { sourceHead :: HeadName,
                                       targetHead :: HeadName }
                      deriving (Eq, Show)
