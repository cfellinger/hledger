{-|

A 'Posting' represents a change (by some 'MixedAmount') of the balance in
some 'Account'.  Each 'Transaction' contains two or more postings which
should add up to 0. Postings reference their parent transaction, so we can
look up the date or description there.

-}

{-# LANGUAGE OverloadedStrings #-}

module Hledger.Data.Posting (
  -- * Posting
  nullposting,
  posting,
  post,
  -- * operations
  originalPosting,
  postingStatus,
  isReal,
  isVirtual,
  isBalancedVirtual,
  isEmptyPosting,
  isAssignment,
  hasAmount,
  postingAllTags,
  transactionAllTags,
  postingAllImplicitTags,
  relatedPostings,
  removePrices,
  -- * date operations
  postingDate,
  postingDate2,
  isPostingInDateSpan,
  isPostingInDateSpan',
  postingsDateSpan,
  postingsDateSpan',
  -- * account name operations
  accountNamesFromPostings,
  accountNamePostingType,
  accountNameWithoutPostingType,
  accountNameWithPostingType,
  joinAccountNames,
  concatAccountNames,
  accountNameApplyAliases,
  accountNameApplyAliasesMemo,
  -- * transaction description operations
  transactionPayee,
  transactionNote,
  payeeAndNoteFromDescription,
  -- * arithmetic
  sumPostings,
  -- * rendering
  showPosting,
  -- * misc.
  showComment,
  tests_Hledger_Data_Posting
)
where
import Data.List
import Data.Maybe
import Data.MemoUgly (memo)
import Data.Monoid
import Data.Ord
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar
import Safe
import Test.HUnit

import Hledger.Utils
import Hledger.Data.Types
import Hledger.Data.Amount
import Hledger.Data.AccountName
import Hledger.Data.Dates (nulldate, spanContainsDate)


instance Show Posting where show = showPosting

nullposting, posting :: Posting
nullposting = Posting
                {pdate=Nothing
                ,pdate2=Nothing
                ,pstatus=Uncleared
                ,paccount=""
                ,pamount=nullmixedamt
                ,pcomment=""
                ,ptype=RegularPosting
                ,ptags=[]
                ,pbalanceassertion=Nothing
                ,ptransaction=Nothing
                ,porigin=Nothing
                }
posting = nullposting

post :: AccountName -> Amount -> Posting
post acct amt = posting {paccount=acct, pamount=Mixed [amt]}

-- Get the original posting, if any.
originalPosting :: Posting -> Posting
originalPosting p = fromMaybe p $ porigin p

-- XXX once rendered user output, but just for debugging now; clean up
showPosting :: Posting -> String
showPosting p@Posting{paccount=a,pamount=amt,ptype=t} =
    unlines $ [concatTopPadded [show (postingDate p) ++ " ", showaccountname a ++ " ", showamount amt, showComment (pcomment p)]]
    where
      ledger3ishlayout = False
      acctnamewidth = if ledger3ishlayout then 25 else 22
      showaccountname = fitString (Just acctnamewidth) Nothing False False . bracket . T.unpack . elideAccountName width
      (bracket,width) = case t of
                          BalancedVirtualPosting -> (\s -> "["++s++"]", acctnamewidth-2)
                          VirtualPosting -> (\s -> "("++s++")", acctnamewidth-2)
                          _ -> (id,acctnamewidth)
      showamount = padLeftWide 12 . showMixedAmount


showComment :: Text -> String
showComment t = if T.null t then "" else "  ;" ++ T.unpack t

isReal :: Posting -> Bool
isReal p = ptype p == RegularPosting

isVirtual :: Posting -> Bool
isVirtual p = ptype p == VirtualPosting

isBalancedVirtual :: Posting -> Bool
isBalancedVirtual p = ptype p == BalancedVirtualPosting

hasAmount :: Posting -> Bool
hasAmount = (/= missingmixedamt) . pamount

isAssignment :: Posting -> Bool
isAssignment p = not (hasAmount p) && isJust (pbalanceassertion p)

accountNamesFromPostings :: [Posting] -> [AccountName]
accountNamesFromPostings = nub . map paccount

sumPostings :: [Posting] -> MixedAmount
sumPostings = sumStrict . map pamount

-- | Remove all prices of a posting
removePrices :: Posting -> Posting
removePrices p = p{ pamount = Mixed $ remove <$> amounts (pamount p) }
  where remove a = a { aprice = NoPrice }

-- | Get a posting's (primary) date - it's own primary date if specified,
-- otherwise the parent transaction's primary date, or the null date if
-- there is no parent transaction.
postingDate :: Posting -> Day
postingDate p = fromMaybe txndate $ pdate p
    where
      txndate = maybe nulldate tdate $ ptransaction p

-- | Get a posting's secondary (secondary) date, which is the first of:
-- posting's secondary date, transaction's secondary date, posting's
-- primary date, transaction's primary date, or the null date if there is
-- no parent transaction.
postingDate2 :: Posting -> Day
postingDate2 p = headDef nulldate $ catMaybes dates
  where dates = [pdate2 p
                ,maybe Nothing tdate2 $ ptransaction p
                ,pdate p
                ,maybe Nothing (Just . tdate) $ ptransaction p
                ]

-- | Get a posting's cleared status: cleared or pending if those are
-- explicitly set, otherwise the cleared status of its parent
-- transaction, or uncleared if there is no parent transaction. (Note
-- Uncleared's ambiguity, it can mean "uncleared" or "don't know".
postingStatus :: Posting -> ClearedStatus
postingStatus Posting{pstatus=s, ptransaction=mt}
  | s == Uncleared = case mt of Just t  -> tstatus t
                                Nothing -> Uncleared
  | otherwise = s

-- | Implicit tags for this transaction.
transactionImplicitTags :: Transaction -> [Tag]
transactionImplicitTags t = filter (not . T.null . snd) [("code", tcode t)
                                                        ,("description", tdescription t)
                                                        ,("payee", transactionPayee t)
                                                        ,("note", transactionNote t)
                                                        ]

transactionPayee :: Transaction -> Text
transactionPayee = fst . payeeAndNoteFromDescription . tdescription

transactionNote :: Transaction -> Text
transactionNote = fst . payeeAndNoteFromDescription . tdescription

-- | Parse a transaction's description into payee and note (aka narration) fields,
-- assuming a convention of separating these with | (like Beancount).
-- Ie, everything up to the first | is the payee, everything after it is the note.
-- When there's no |, payee == note == description.
payeeAndNoteFromDescription :: Text -> (Text,Text)
payeeAndNoteFromDescription t = (textstrip p, textstrip $ T.tail n)
  where
    (p,n) = T.breakOn "|" t

-- | Tags for this posting including implicit and any inherited from its parent transaction.
postingAllImplicitTags :: Posting -> [Tag]
postingAllImplicitTags p = ptags p ++ maybe [] transactionTags (ptransaction p)
    where transactionTags t = ttags t ++ transactionImplicitTags t

-- | Tags for this posting including any inherited from its parent transaction.
postingAllTags :: Posting -> [Tag]
postingAllTags p = ptags p ++ maybe [] ttags (ptransaction p)

-- | Tags for this transaction including any from its postings.
transactionAllTags :: Transaction -> [Tag]
transactionAllTags t = ttags t ++ concatMap ptags (tpostings t)

-- Get the other postings from this posting's transaction.
relatedPostings :: Posting -> [Posting]
relatedPostings p@Posting{ptransaction=Just t} = filter (/= p) $ tpostings t
relatedPostings _ = []

-- | Does this posting fall within the given date span ?
isPostingInDateSpan :: DateSpan -> Posting -> Bool
isPostingInDateSpan s = spanContainsDate s . postingDate

-- --date2-sensitive version, separate for now to avoid disturbing multiBalanceReport.
isPostingInDateSpan' :: WhichDate -> DateSpan -> Posting -> Bool
isPostingInDateSpan' PrimaryDate   s = spanContainsDate s . postingDate
isPostingInDateSpan' SecondaryDate s = spanContainsDate s . postingDate2

isEmptyPosting :: Posting -> Bool
isEmptyPosting = isZeroMixedAmount . pamount

-- | Get the minimal date span which contains all the postings, or the
-- null date span if there are none.
postingsDateSpan :: [Posting] -> DateSpan
postingsDateSpan [] = DateSpan Nothing Nothing
postingsDateSpan ps = DateSpan (Just $ postingDate $ head ps') (Just $ addDays 1 $ postingDate $ last ps')
    where ps' = sortBy (comparing postingDate) ps

-- --date2-sensitive version, as above.
postingsDateSpan' :: WhichDate -> [Posting] -> DateSpan
postingsDateSpan' _  [] = DateSpan Nothing Nothing
postingsDateSpan' wd ps = DateSpan (Just $ postingdate $ head ps') (Just $ addDays 1 $ postingdate $ last ps')
    where
      ps' = sortBy (comparing postingdate) ps
      postingdate = if wd == PrimaryDate then postingDate else postingDate2

-- AccountName stuff that depends on PostingType

accountNamePostingType :: AccountName -> PostingType
accountNamePostingType a
    | T.null a = RegularPosting
    | T.head a == '[' && T.last a == ']' = BalancedVirtualPosting
    | T.head a == '(' && T.last a == ')' = VirtualPosting
    | otherwise = RegularPosting

accountNameWithoutPostingType :: AccountName -> AccountName
accountNameWithoutPostingType a = case accountNamePostingType a of
                                    BalancedVirtualPosting -> T.init $ T.tail a
                                    VirtualPosting -> T.init $ T.tail a
                                    RegularPosting -> a

accountNameWithPostingType :: PostingType -> AccountName -> AccountName
accountNameWithPostingType BalancedVirtualPosting a = "["<>accountNameWithoutPostingType a<>"]"
accountNameWithPostingType VirtualPosting a = "("<>accountNameWithoutPostingType a<>")"
accountNameWithPostingType RegularPosting a = accountNameWithoutPostingType a

-- | Prefix one account name to another, preserving posting type
-- indicators like concatAccountNames.
joinAccountNames :: AccountName -> AccountName -> AccountName
joinAccountNames a b = concatAccountNames $ filter (not . T.null) [a,b]

-- | Join account names into one. If any of them has () or [] posting type
-- indicators, these (the first type encountered) will also be applied to
-- the resulting account name.
concatAccountNames :: [AccountName] -> AccountName
concatAccountNames as = accountNameWithPostingType t $ T.intercalate ":" $ map accountNameWithoutPostingType as
    where t = headDef RegularPosting $ filter (/= RegularPosting) $ map accountNamePostingType as

-- | Rewrite an account name using all matching aliases from the given list, in sequence.
-- Each alias sees the result of applying the previous aliases.
accountNameApplyAliases :: [AccountAlias] -> AccountName -> AccountName
accountNameApplyAliases aliases a = accountNameWithPostingType atype aname'
  where
    (aname,atype) = (accountNameWithoutPostingType a, accountNamePostingType a)
    aname' = foldl
             (\acct alias -> dbg6 "result" $ aliasReplace (dbg6 "alias" alias) (dbg6 "account" acct))
             aname
             aliases

-- | Memoising version of accountNameApplyAliases, maybe overkill.
accountNameApplyAliasesMemo :: [AccountAlias] -> AccountName -> AccountName
accountNameApplyAliasesMemo aliases = memo (accountNameApplyAliases aliases)

-- aliasMatches :: AccountAlias -> AccountName -> Bool
-- aliasMatches (BasicAlias old _) a = old `isAccountNamePrefixOf` a
-- aliasMatches (RegexAlias re  _) a = regexMatchesCI re a

aliasReplace :: AccountAlias -> AccountName -> AccountName
aliasReplace (BasicAlias old new) a
  | old `isAccountNamePrefixOf` a || old == a = new <> T.drop (T.length old) a
  | otherwise = a
aliasReplace (RegexAlias re repl) a = T.pack $ regexReplaceCIMemo re repl $ T.unpack a -- XXX


tests_Hledger_Data_Posting = TestList [

  "accountNamePostingType" ~: do
    accountNamePostingType "a" `is` RegularPosting
    accountNamePostingType "(a)" `is` VirtualPosting
    accountNamePostingType "[a]" `is` BalancedVirtualPosting

 ,"accountNameWithoutPostingType" ~: do
    accountNameWithoutPostingType "(a)" `is` "a"

 ,"accountNameWithPostingType" ~: do
    accountNameWithPostingType VirtualPosting "[a]" `is` "(a)"

 ,"joinAccountNames" ~: do
    "a" `joinAccountNames` "b:c" `is` "a:b:c"
    "a" `joinAccountNames` "(b:c)" `is` "(a:b:c)"
    "[a]" `joinAccountNames` "(b:c)" `is` "[a:b:c]"
    "" `joinAccountNames` "a" `is` "a"

 ,"concatAccountNames" ~: do
    concatAccountNames [] `is` ""
    concatAccountNames ["a","(b)","[c:d]"] `is` "(a:b:c:d)"

 ]

