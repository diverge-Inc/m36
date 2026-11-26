{-# LANGUAGE DeriveGeneric #-}
module ProjectM36.DisconnectedTransaction where
import ProjectM36.Base
import qualified ProjectM36.IsomorphicSchema.Types as Schema
import ProjectM36.IsomorphicSchema.Types (Schemas)
import ProjectM36.Transaction.Types (Transaction)
import qualified ProjectM36.Transaction.Types as Trans
import ProjectM36.DatabaseContext as DBC
import ProjectM36.DatabaseContext.Types as DBC
import GHC.Generics
import ProjectM36.ValueMarker

-- | Every set of modifications made to the database are atomically committed to the transaction graph as a transaction.

-- | The disconnected transaction represents an in-progress workspace used by sessions before changes are committed. This is similar to git's "index". After a transaction is committed, it is "connected" in the transaction graph and can no longer be modified.

data DisconnectedTransaction = DisconnectedTransaction {
  disconTransactionId :: TransactionId,
  disconSchemas :: Schemas DatabaseContext,
  disconCurrentHead :: CurrentHead
  }

data CurrentHead = CurrentHeadBranch HeadName | -- ^ track a branch
                   CurrentHeadTransactionId TransactionId -- ^ peg to a transaction which is not a head
                   deriving (Show, Eq, Generic)

type TransactionRefSchemas = Schemas DatabaseContext

--the database context expression represents a difference between the disconnected transaction and its immutable parent transaction- is this diff expr used at all?

concreteDatabaseContext :: DisconnectedTransaction -> DatabaseContext
concreteDatabaseContext discon = Schema.concreteDatabaseContext (disconSchemas discon)

parentId :: DisconnectedTransaction -> TransactionId
parentId = disconTransactionId

isUpdated :: DisconnectedTransaction -> Bool
isUpdated disconTrans = DBC.isUpdated (concreteDatabaseContext disconTrans)

-- | The workspace of a session on top of a committed transaction, before the session has changed anything. Every field refers to the transaction which holds its value, so the workspace is not dirty and committing it would store nothing again.
--
-- Used wherever a session comes to rest on a transaction: when it is created, after a commit, a rollback, a merge, or a jump to another point of the graph.
fromTransaction :: CurrentHead -> Transaction -> DisconnectedTransaction
fromTransaction head' trans =
  DisconnectedTransaction {
  disconTransactionId = tid,
  disconSchemas = Schema.Schemas {
      Schema.concreteDatabaseContext = unchangedDatabaseContext tid (Schema.concreteDatabaseContext transSchemas),
      Schema.subschemas = unchangedSince tid (Schema.subschemas transSchemas)
      },
  disconCurrentHead = head'
  }
  where
    tid = Trans.transactionId trans
    transSchemas = Trans.schemas trans
