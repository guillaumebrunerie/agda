{-# LANGUAGE CPP #-}

module Agda.TypeChecking.InstanceArguments where

import Control.Applicative
import Control.Monad.Error
import Control.Monad.Reader
import Control.Monad.State
import qualified Data.Map as Map
import Data.List as List

import Agda.Syntax.Common
import Agda.Syntax.Position
import Agda.Syntax.Scope.Base
import Agda.Syntax.Internal as I

import Agda.TypeChecking.Irrelevance
import Agda.TypeChecking.Monad
import Agda.TypeChecking.Pretty
import Agda.TypeChecking.Substitute
import Agda.TypeChecking.Reduce
import Agda.TypeChecking.Telescope

import {-# SOURCE #-} Agda.TypeChecking.Constraints
import {-# SOURCE #-} Agda.TypeChecking.Rules.Term (checkArguments)
import {-# SOURCE #-} Agda.TypeChecking.MetaVars
import {-# SOURCE #-} Agda.TypeChecking.Conversion

import Agda.Utils.Maybe
import Agda.Utils.Monad

#include "../undefined.h"
import Agda.Utils.Impossible

-- | A candidate solution for an instance meta is a term with its type.
type Candidates = [(Term, Type)]

initialIFSCandidates :: Type -> TCM (Maybe Candidates)
initialIFSCandidates t = do
  cands1 <- getContextVars
  otn <- getOutputTypeName t
  case otn of
    NoOutputTypeName -> typeError $ GenericError $ "Instance search can only be used to find elements in a named type"
    OutputTypeNameNotYetKnown -> return Nothing
    OutputTypeName n -> do
      cands2 <- getScopeDefs n
      return $ Just $ cands1 ++ cands2
  where
    -- get a list of variables with their type, relative to current context
    getContextVars :: TCM Candidates
    getContextVars = do
      ctx <- getContext
      let vars = [ (var i, raise (i + 1) t)
                 | (Dom info (x, t), i) <- zip ctx [0..]
                 , not (unusableRelevance $ argInfoRelevance info)
                 ]
      -- get let bindings
      env <- asks envLetBindings
      env <- mapM (getOpen . snd) $ Map.toList env
      let lets = [ (v,t)
                 | (v, Dom info t) <- env
                 , not (unusableRelevance $ argInfoRelevance info)
                 ]
      return $ vars ++ lets

    getScopeDefs :: QName -> TCM Candidates
    getScopeDefs n = do
      instanceDefs <- getInstanceDefs
      let qs = caseMaybe (Map.lookup n instanceDefs) [] (\l -> l)
      rel   <- asks envRelevance
      cands <- mapM (candidate rel) qs
      return $ concat cands

    candidate :: Relevance -> QName -> TCM Candidates
    candidate rel q =
      -- Andreas, 2012-07-07:
      -- we try to get the info for q
      -- while opening a module, q may be in scope but not in the signature
      -- in this case, we just ignore q (issue 674)
      flip catchError handle $ do
        def <- getConstInfo q
        let r = defRelevance def
        if not (r `moreRelevant` rel) then return [] else do
          t   <- defType <$> instantiateDef def
          args <- freeVarsToApply q
          let v = case theDef def of
               -- drop parameters if it's a projection function...
               Function{ funProjection = Just p } -> Def q $ map Apply $ genericDrop (projIndex p - 1) args
               Constructor{}                      -> Con (ConHead q []) []
               _                                  -> Def q $ map Apply args
          return [(v, t)]
      where
        -- unbound constant throws an internal error
        handle (TypeError _ (Closure {clValue = InternalError _})) = return []
        handle err                                                 = throwError err

-- | @initializeIFSMeta s t@ generates an instance meta of type @t@
--   with suggested name @s@.
initializeIFSMeta :: String -> Type -> TCM Term
initializeIFSMeta s t = do
  cands <- initialIFSCandidates t
  newIFSMeta s t cands

-- | @findInScope m (v,a)s@ tries to instantiate on of the types @a@s
--   of the candidate terms @v@s to the type @t@ of the metavariable @m@.
--   If successful, meta @m@ is solved with the instantiation of @v@.
--   If unsuccessful, the constraint is regenerated, with possibly reduced
--   candidate set.
--   The list of candidates is equal to @Nothing@ when the type of the meta
--   wasn't known when the constraint was generated. In that case, try to find
--   its type again.
findInScope :: MetaId -> Maybe Candidates -> TCM ()
findInScope m Nothing = do
  reportSLn "tc.constr.findInScope" 20 $ "The type of the FindInScope constraint isn't known, trying to find it again."
  t <- getMetaType m
  cands <- initialIFSCandidates t
  case cands of
    Nothing -> addConstraint $ FindInScope m Nothing
    Just c -> findInScope m cands
findInScope m (Just cands) = whenJustM (findInScope' m cands) $ addConstraint . FindInScope m . Just

-- | Result says whether we need to add constraint, and if so, the set of
--   remaining candidates.
findInScope' :: MetaId -> Candidates -> TCM (Maybe Candidates)
findInScope' m cands = ifM (isFrozen m) (return (Just cands)) $ do
    -- Andreas, 2013-12-28 issue 1003:
    -- If instance meta is already solved, simply discard the constraint.
    ifM (isInstantiatedMeta m) (return Nothing) $ do
    reportSDoc "tc.constr.findInScope" 15 $ text ("findInScope 2: constraint: " ++ show m ++ "; candidates left: " ++ show (length cands))
    t <- normalise =<< getMetaTypeInContext m
    reportSDoc "tc.constr.findInScope" 15 $ text "findInScope 3: t =" <+> prettyTCM t
    reportSLn "tc.constr.findInScope" 70 $ "findInScope 3: t: " ++ show t
    mv <- lookupMeta m
    -- Don't do anything if there are unsolved metas in the type, or else it could loop
    allMetasAreSolved <- isInstantiatedMeta (allMetas t)
    -- But if there are no recursive instances, it's still safe to perform instance search
    let isRec = foldl (\ b (_, t) -> b || (isRecursive $ unEl t)) False cands
    cands <- if allMetasAreSolved || not isRec then checkCandidates m t cands else return cands
    reportSLn "tc.constr.findInScope" 15 $ "findInScope 4: cands left: " ++ show (length cands)
    case cands of

      [] -> do
        reportSDoc "tc.constr.findInScope" 15 $ text "findInScope 5: not a single candidate found..."
        typeError $ IFSNoCandidateInScope t

      [(term, t')] -> do
        reportSDoc "tc.constr.findInScope" 15 $ text (
          "findInScope 5: one candidate found for type '") <+>
          prettyTCM t <+> text "': '" <+> prettyTCM term <+>
          text "', of type '" <+> prettyTCM t' <+> text "'."

        -- if t' takes initial hidden arguments, apply them
        ca <- liftTCM $ runErrorT $ checkArguments ExpandLast ExpandInstanceArguments (getRange mv) [] t' t
        case ca of
          Left _ -> __IMPOSSIBLE__
          Right (args, t'') -> do
            -- @args@ are the hidden arguments @t'@ takes, @t''@ is @t' `apply` args@
{- TODO
        (args, t'') <- implicitArgs (...) t'
        do
-}
            leqType t'' t
            ctxArgs <- getContextArgs
            v <- (`applyDroppingParameters` args) =<< reduce term
            assignV DirEq m ctxArgs v
            reportSDoc "tc.constr.findInScope" 10 $
              text "solved by instance search:" <+> prettyTCM m
              <+> text ":=" <+> prettyTCM v
            return Nothing

      cs -> do
        reportSDoc "tc.constr.findInScope" 15 $
          text ("findInScope 5: more than one candidate found: ") <+>
          prettyTCM (List.map fst cs)
        return (Just cs)
    where
      isRecursive :: Term -> Bool
      isRecursive (Pi (Dom info _) t) = getHiding info == Instance || isRecursive (unEl $ unAbs t)
      isRecursive _ = False

-- | Given a meta @m@ of type @t@ and a list of candidates @cands@,
-- @checkCandidates m t cands@ returns a refined list of valid candidates.
checkCandidates :: MetaId -> Type -> Candidates -> TCM Candidates
checkCandidates m t cands = localTCState $ disableDestructiveUpdate $ do
  -- for candidate checking, we don't take into account other IFS
  -- constraints
  dropConstraints (isIFSConstraint . clValue . theConstraint)
  cands <- filterM (uncurry $ checkCandidateForMeta m t) cands
  -- Drop all candidates which are equal to the first one
  dropSameCandidates cands
  where
    checkCandidateForMeta :: MetaId -> Type -> Term -> Type -> TCM Bool
    checkCandidateForMeta m t term t' =
      verboseBracket "tc.constr.findInScope" 20 ("checkCandidateForMeta " ++ show m) $ do
      liftTCM $ flip catchError handle $ do
        reportSLn "tc.constr.findInScope" 70 $ "  t: " ++ show t ++ "\n  t':" ++ show t' ++ "\n  term: " ++ show term ++ "."
        reportSDoc "tc.constr.findInScope" 20 $ vcat
          [ text "checkCandidateForMeta"
          , text "t    =" <+> prettyTCM t
          , text "t'   =" <+> prettyTCM t'
          , text "term =" <+> prettyTCM term
          ]
        localTCState $ do
           -- domi: we assume that nothing below performs direct IO (except
           -- for logging and such, I guess)
          ca <- runErrorT $ checkArguments ExpandLast ExpandInstanceArguments noRange [] t' t
          case ca of
            Left _ -> return False
            Right (args, t'') -> do
              reportSDoc "tc.constr.findInScope" 20 $
                text "instance search: checking" <+> prettyTCM t''
                <+> text "<=" <+> prettyTCM t
              -- if constraints remain, we abort, but keep the candidate
              flip (ifNoConstraints_ $ leqType t'' t) (const $ return True) $ do
              --tel <- getContextTelescope
              ctxArgs <- getContextArgs
              v <- (`applyDroppingParameters` args) =<< reduce term
              reportSDoc "tc.constr.findInScope" 10 $
                text "instance search: attempting" <+> prettyTCM m
                <+> text ":=" <+> prettyTCM v
              assign DirEq m ctxArgs v
--              assign m ctxArgs (term `apply` args)
              -- make a pass over constraints, to detect cases where some are made
              -- unsolvable by the assignment, but don't do this for FindInScope's
              -- to prevent loops. We currently also ignore UnBlock constraints
              -- to be on the safe side.
              solveAwakeConstraints' True
              return True
      where
        handle err = do
          reportSDoc "tc.constr.findInScope" 50 $ text "assignment failed:" <+> prettyTCM err
          return False
    isIFSConstraint :: Constraint -> Bool
    isIFSConstraint FindInScope{} = True
    isIFSConstraint UnBlock{}     = True -- otherwise test/fail/Issue723 loops
    isIFSConstraint _             = False

    -- Drop all candidates which are judgmentally equal to the first one.
    -- This is sufficient to reduce the list to a singleton should all be equal.
    dropSameCandidates :: Candidates -> TCM Candidates
    dropSameCandidates cands = do
      case cands of
        []            -> return cands
        c@(v,a) : vas -> (c:) <$> dropWhileM equal vas
          where
            equal (v',a') = dontAssignMetas $ ifNoConstraints_ (equalType a a' >> equalTerm a v v')
                              {- then -} (return True)
                              {- else -} (\ _ -> return False)
                            `catchError` (\ _ -> return False)

-- | To preserve the invariant that a constructor is not applied to its
--   parameter arguments, we explicitly check whether function term
--   we are applying to arguments is a unapplied constructor.
--   In this case we drop the first 'conPars' arguments.
--   See Issue670a.
--   Andreas, 2013-11-07 Also do this for projections, see Issue670b.
applyDroppingParameters :: Term -> Args -> TCM Term
applyDroppingParameters t vs = do
  let fallback = return $ t `apply` vs
  case ignoreSharing t of
    Con c [] -> do
      def <- theDef <$> getConInfo c
      case def of
        Constructor {conPars = n} -> return $ Con c (genericDrop n vs)
        _ -> __IMPOSSIBLE__
    Def f [] -> do
      mp <- isProjection f
      case mp of
        Just Projection{projIndex = n} -> do
          case drop n vs of
            []     -> return t
            u : us -> (`apply` us) <$> applyDef f u
        _ -> fallback
    _ -> fallback
