module Main where

import Directory    ( doesFileExist )
import FilePath     ( (</>) )
import IOExts
import List         ( (\\), elemIndex, find, isSuffixOf
                    , maximum, minimum, splitOn )
import Maybe        ( catMaybes )
import State
import System

-- Imports from dependencies:
import Analysis.ProgInfo
import Analysis.TotallyDefined ( siblingCons )
import Analysis.Types
import CASS.Server             ( analyzeGeneric, analyzePublic )
import FlatCurry.Annotated.Types
import FlatCurry.Files
import qualified FlatCurry.Goodies as FCG
--import FlatCurry.Annotated.Files   ( readTypedFlatCurry )
import FlatCurry.Annotated.Goodies
import ShowFlatCurry                     ( showCurryModule )

-- Imports from package modules:
import BoolExp
import Curry2SMT
import PackageConfig ( packagePath )
import AnalysisOptions
import PatternAnalysis
import VerificationState
import TypedFlatCurryGoodies

test :: Int -> String -> IO ()
test v = analyzeNonFailing defaultOptions { optVerb = v }

testv :: String -> IO ()
testv = analyzeNonFailing defaultOptions { optVerb = 3 }

------------------------------------------------------------------------

banner :: String
banner = unlines [bannerLine,bannerText,bannerLine]
 where
   bannerText = "Non-Failing Analysis Tool (Version of xx/04/18)"
   bannerLine = take (length bannerText) (repeat '=')

---------------------------------------------------------------------------
main :: IO ()
main = do
  args <- getArgs
  (opts,progs) <- processOptions banner args
  z3exists <- fileInPath "z3"
  if z3exists
    then do
      when (optVerb opts > 0) $ putStrLn banner
      mapIO_ (analyzeNonFailing opts) progs
    else do
      putStrLn "NON-FAILING ANALYSIS SKIPPED:"
      putStrLn "The SMT solver Z3 is required for the analyzer to work"
      putStrLn "but the program 'z3' is not found on the PATH!"


analyzeNonFailing :: Options -> String -> IO ()
analyzeNonFailing opts modname = do
  prog <- readTypedFlatCurry modname
  siblingconsinfo <- loadAnalysisWithImports siblingCons prog
  printWhenAll opts $ unlines $
    ["ORIGINAL PROGRAM:", line, showCurryModule (unAnnProg prog), line]
  stats <- verifyNonFailing opts siblingconsinfo
                        (makeTransInfo opts (progFuncs prog))
                        prog initVState
  printWhenStatus opts (showStats stats)
 where
  line = take 78 (repeat '-')

-- Loads CASS analysis results for a module and its imported entities.
loadAnalysisWithImports :: Analysis a -> TAProg -> IO (ProgInfo a)
loadAnalysisWithImports analysis prog = do
  maininfo <- analyzeGeneric analysis (progName prog)
                >>= return . either id error
  impinfos <- mapIO (\m -> analyzePublic analysis m >>=
                                                     return . either id error)
                    (progImports prog)
  return $ foldr combineProgInfo maininfo impinfos

---------------------------------------------------------------------------

printWhenStatus :: Options -> String -> IO ()
printWhenStatus opts s =
  when (optVerb opts > 0) (printWT s)

printWhenIntermediate :: Options -> String -> IO ()
printWhenIntermediate opts s =
  when (optVerb opts > 1) (printWT s)

printWhenAll :: Options -> String -> IO ()
printWhenAll opts s =
 when (optVerb opts > 2) (printWT s)

printWT :: String -> IO ()
printWT s = putStrLn $ "NON-FAILING ANALYSIS: " ++ s

---------------------------------------------------------------------------
-- Some global information used by the transformation process:
data TransInfo = TransInfo
  { tiOptions     :: Options      -- options passed to all defined operations
  , allFuns       :: [TAFuncDecl] -- all defined operations
  , preConds      :: [TAFuncDecl] -- all precondition operations
  , postConds     :: [TAFuncDecl] -- all postcondition operations
  , nfConds       :: [TAFuncDecl] -- all non-failure condition operations
  }

makeTransInfo :: Options -> [TAFuncDecl] -> TransInfo
makeTransInfo opts fdecls = TransInfo opts fdecls preconds postconds nfconds
 where
  -- Precondition operations:
  preconds  = filter (\fd -> "'pre"     `isSuffixOf` snd (funcName fd)) fdecls
  -- Postcondition operations:
  postconds = filter (\fd -> "'post"    `isSuffixOf` snd (funcName fd)) fdecls
  -- Non-failure condition operations:
  nfconds   = filter (\fd -> "'nonfail" `isSuffixOf` snd (funcName fd)) fdecls

--- Is an operation name the name of a contract or similar?
isContractOp :: QName -> Bool
isContractOp (_,fn) =
  "'nonfail" `isSuffixOf` fn ||
  "'pre"     `isSuffixOf` fn ||
  "'post"    `isSuffixOf` fn

---------------------------------------------------------------------------
-- The state of the transformation process contains
-- * the current assertion
-- * a fresh variable index
-- * a list of all introduced variables and their types:
data TransState = TransState
  { preCond    :: BoolExp
  , freshVar   :: Int
  , varTypes   :: [(Int,TypeExpr)]
  }

makeTransState :: Int -> [(Int,TypeExpr)] -> TransState
makeTransState = TransState bTrue

-- Increments fresh variable index.
incFreshVarIndex :: TransState -> TransState
incFreshVarIndex st = st { freshVar = freshVar st + 1 }

-- Adds variables to the state.
addVarTypes :: [(Int,TypeExpr)] -> TransState -> TransState
addVarTypes vts st = st { varTypes = vts ++ varTypes st }

---------------------------------------------------------------------------
-- Eliminate possible preconditions checks:
-- If an operation `f` occurring in a right-hand side has
-- a precondition check, a proof for the validity of the precondition
-- is extracted and, if the proof is successful, the operation without
-- the precondtion check `f'WithoutPreCondCheck` is called instead.
verifyNonFailing :: Options -> ProgInfo [(QName,Int)] -> TransInfo -> TAProg
                 -> VState -> IO VState
verifyNonFailing opts siblingconsinfo ti prog stats = do
  vstref <- newIORef stats
  mapIO_ (proveNonFailingFunc opts siblingconsinfo ti vstref) (progFuncs prog)
  readIORef vstref

proveNonFailingFunc :: Options -> ProgInfo [(QName,Int)] -> TransInfo
                    -> IORef VState -> TAFuncDecl -> IO ()
proveNonFailingFunc opts siblingconsinfo ti vstref fdecl =
  unless (isContractOp (funcName fdecl)) $ do
    printWhenIntermediate opts $
      "Operation to be analyzed: " ++ snd (funcName fdecl)
    modifyIORef vstref incNumAllInStats
    proveNonFailingRule opts siblingconsinfo ti
      (funcName fdecl) (funcRule fdecl) vstref

proveNonFailingRule :: Options -> ProgInfo [(QName,Int)] -> TransInfo
                    -> QName -> TARule -> IORef VState -> IO ()
proveNonFailingRule _ _ _ _ (AExternal _ _) _ = done
proveNonFailingRule opts siblingconsinfo ti (mn,fn)
                    (ARule _ rargs rhs) vstref = do
  let farity = length rargs
      orgqn = (mn,fn)
      -- compute non-fail precondition of operation:
      s0 = makeTransState (maximum (0 : map fst rargs ++ allVars rhs) + 1) rargs
      (precondformula,s1)  = nonfailCondExpOf ti orgqn [1..farity] s0
      s2 = s1 { preCond = precondformula }
  proveNonFailExp s2 rhs
 where
  proveNonFailExp pts exp = case exp of
    AComb ty ct (qf,_) args ->
      if qf == ("Prelude","?") && length args == 2
        then proveNonFailExp pts (AOr ty (args!!0) (args!!1))
        else do
          mapIO_ (proveNonFailExp pts) args
          when (isCombTypeFuncPartCall ct) $
            let qnpre = addSuffix qf "'nonfail"
            in maybe done -- h.o. call nonfailing if op. has no non-fail cond.
                 (\_ -> do
                   let reason = "due to call '" ++ ppTAExpr exp ++ "'"
                   modifyIORef vstref (addFailedFuncToStats fn reason)
                   printWhenStatus opts $
                     fn ++ ": POSSIBLY FAILING CALL OF '" ++ snd qf ++ "'")
                     (find (\fd -> funcName fd == qnpre) (nfConds ti))
          when (ct==FuncCall) $ do
            printWhenIntermediate opts $ "Analyzing call to " ++ snd qf
            let ((bs,_)    ,pts1) = normalizeArgs args pts
                (bindexps  ,pts2) = mapS (exp2bool True ti) bs pts1
                (nfcondcall,pts3) = nonfailCondExpOf ti qf (map fst bs) pts2
            -- TODO: select from 'bindexps' only demanded argument positions
            valid <- if nfcondcall == bTrue
                       then return (Just True) -- true non-fail cond. is valid
                       else checkImplicationWithSMT opts vstref (varTypes pts3)
                              (preCond pts) (Conj bindexps) nfcondcall
            if valid == Just True
              then do
                printWhenIntermediate opts $
                  fn ++ ": NON-FAILING CALL OF '" ++ snd qf ++ "'"
              else do
                let reason = if valid == Nothing
                               then "due to SMT error"
                               else "due to call '" ++ ppTAExpr exp ++ "'"
                modifyIORef vstref (addFailedFuncToStats fn reason)
                printWhenStatus opts $
                  fn ++ ": POSSIBLY FAILING CALL OF '" ++ snd qf ++ "'"
    ACase _ _ e brs -> do
      proveNonFailExp pts e
      maybe
       (let freshvar = freshVar pts
            (be,pts1) = exp2bool True ti (freshvar,e) (incFreshVarIndex pts)
            pts2 = pts1 { preCond = Conj [preCond pts, be]
                        , varTypes = (freshvar, annExpr e) : varTypes pts1 }
            misscons = missingConsInBranch siblingconsinfo brs
        in do mapIO_ (verifyMissingCons pts2 freshvar (annExpr e)) misscons
              mapIO_ (proveNonFailBranch pts2 freshvar) brs
       )
       (\ (fe,te) ->
           let (be,pts1) = pred2bool e pts
               ptsf = pts1 { preCond = Conj [preCond pts, bNot be] }
               ptst = pts1 { preCond = Conj [preCond pts, be] }
           in do proveNonFailExp ptsf fe
                 proveNonFailExp ptst te
       )
       (testBoolCase brs)
    AOr _ e1 e2 -> do proveNonFailExp pts e1
                      proveNonFailExp pts e2
    ALet _ bs e -> do mapIO_ (proveNonFailExp pts) (map snd bs)
                      proveNonFailExp pts e
    AFree _ _ e -> proveNonFailExp pts e
    ATyped _ e _ -> proveNonFailExp pts e
    _ -> done

  verifyMissingCons pts dvar dvartype (cons,_) = do
    printWhenIntermediate opts $
      fn ++ ": checking missing constructor case '" ++ snd cons ++ "'"
    valid <- checkImplicationWithSMT opts vstref (varTypes pts) (preCond pts)
                bTrue (bNot (constructorTest cons dvar dvartype))
    unless (valid == Just True) $ do
      let reason = if valid == Nothing
                     then "due to SMT error"
                     else "maybe not defined on constructor '" ++
                          showQName cons ++ "'"
      modifyIORef vstref (addFailedFuncToStats fn reason)
      putStrLn $ "POSSIBLY FAILING BRANCH in function '" ++ fn ++
                 "' with constructor " ++ snd cons

  proveNonFailBranch pts dvar branch = do
    let (ABranch p e, pts1) = renamePatternVars pts branch
    let npts = pts1 { preCond = Conj [preCond pts1, bEquVar dvar (pat2bool p)] }
    proveNonFailExp npts e

--- Translates a constructor name and a variable into a SMT formula
--- implementing a test for this constructor.
constructorTest :: QName -> Int -> TypeExpr -> BoolExp
constructorTest qn var vartype
  | qn == pre "[]"
  = bEquVar var (BTerm "as" [BTerm "nil" [], type2SMTExp vartype])
  | qn `elem` [pre "[]", pre "True", pre "False"]
  = bEquVar var (BTerm (transOpName qn) [])
  | otherwise = error $ "Test for constructor " ++ showQName qn ++
                        " not yet supported!"


missingConsInBranch :: ProgInfo [(QName,Int)] -> [TABranchExpr] -> [(QName,Int)]
missingConsInBranch _ [] =
  error "missingConsInBranch: case with empty branches!"
missingConsInBranch _ (ABranch (ALPattern _ _) _ : _) =
  error "TODO: case with literal pattern"
missingConsInBranch siblingconsinfo
                    (ABranch (APattern _ (cons,_) _) _ : brs) =
  let othercons = maybe (error $ "Sibling constructors of " ++
                                 showQName cons ++ " not found!")
                        id
                        (lookupProgInfo cons siblingconsinfo)
      branchcons = map (patCons . branchPattern) brs
  in filter ((`notElem` branchcons) . fst) othercons

-- Translates a FlatCurry expression to a Boolean formula representing
-- the postcondition assertion by generating an equation
-- between the argument variable (represented by its index in the first
-- component) and the translated expression (second component).
-- The translated expression is normalized when necessary.
-- For this purpose, a "fresh variable index" is passed as a state.
-- Moreover, the returned state contains also the types of all fresh variables.
-- If the first argument is `False`, the expression is not strictly demanded,
-- i.e., possible contracts of it (if it is a function call) are ignored.
exp2bool :: Bool -> TransInfo -> (Int,TAExpr) -> State TransState BoolExp
exp2bool demanded ti (resvar,exp) = case exp of
  AVar _ i -> returnS $ if resvar==i then bTrue
                                     else bEquVar resvar (BVar i)
  ALit _ l -> returnS (bEquVar resvar (lit2bool l))
  AComb ty _ (qf,_) args ->
    if qf == ("Prelude","?") && length args == 2
      then exp2bool demanded ti (resvar, AOr ty (args!!0) (args!!1))
      else normalizeArgs args `bindS` \ (bs,nargs) ->
           -- TODO: select from 'bindexps' only demanded argument positions
           mapS (exp2bool (isPrimOp qf || optStrict (tiOptions ti)) ti)
                bs `bindS` \bindexps ->
           comb2bool qf nargs bs bindexps
  ALet _ bs e ->
    mapS (exp2bool False ti)
         (map (\ ((i,_),ae) -> (i,ae)) bs) `bindS` \bindexps ->
    exp2bool demanded ti (resvar,e) `bindS` \bexp ->
    returnS (Conj (bindexps ++ [bexp]))
  AOr _ e1 e2  ->
    exp2bool demanded ti (resvar,e1) `bindS` \bexp1 ->
    exp2bool demanded ti (resvar,e2) `bindS` \bexp2 ->
    returnS (Disj [bexp1, bexp2])
  ACase _ _ e brs   ->
    getS `bindS` \ts ->
    let freshvar = freshVar ts
    in putS (addVarTypes [(freshvar, annExpr e)] (incFreshVarIndex ts)) `bindS_`
       exp2bool demanded ti (freshvar,e) `bindS` \argbexp ->
       mapS branch2bool (map (\b->(freshvar,b)) brs) `bindS` \bbrs ->
       returnS (Conj [argbexp, Disj bbrs])
  ATyped _ e _ -> exp2bool demanded ti (resvar,e)
  AFree _ _ _ -> error "Free variables not yet supported!"
 where
   comb2bool qf nargs bs bindexps
    | qf == pre "otherwise"
      -- specific handling for the moment since the front end inserts it
      -- as the last alternative of guarded rules...
    = returnS (bEquVar resvar bTrue)
    | qf == pre "[]"
    = returnS (bEquVar resvar (BTerm "nil" []))
    | qf == pre ":" && length nargs == 2
    = returnS (Conj (bindexps ++
                     [bEquVar resvar (BTerm "insert" (map arg2bool nargs))]))
    -- TODO: translate also other data constructors into SMT
    | isPrimOp qf
    = returnS (Conj (bindexps ++
                     [bEquVar resvar (BTerm (transOpName qf)
                                            (map arg2bool nargs))]))
    | otherwise -- non-primitive operation: add contract only if demanded
    = preCondExpOf ti qf (map fst bs) `bindS` \precond ->
      postCondExpOf ti qf (map fst bs ++ [resvar]) `bindS` \postcond ->
      returnS (Conj (bindexps ++ if demanded then [precond,postcond] else []))
   
   branch2bool (cvar, (ABranch p e)) =
     exp2bool demanded ti (resvar,e) `bindS` \branchbexp ->
     getS `bindS` \ts ->
     putS ts { varTypes = patvars ++ varTypes ts} `bindS_`
     returnS (Conj [ bEquVar cvar (pat2bool p), branchbexp])
    where
     patvars = if isConsPattern p
                 then patArgs p
                 else []


   arg2bool e = case e of AVar _ i -> BVar i
                          ALit _ l -> lit2bool l
                          _ -> error $ "Not normalized: " ++ show e

-- Returns the non-failure condition expression for a given operation
-- and its arguments (which are assumed to be variable indices).
-- Rename all local variables by adding the `freshvar` index to them.
nonfailCondExpOf :: TransInfo -> QName -> [Int] -> State TransState BoolExp
nonfailCondExpOf ti qf args =
  maybe (returnS bTrue)
        (\fd -> if funcArity fd /= length args
                  then error $ "Operation '" ++ snd qf ++
                               "': nonfail condition has incorrect arity!"
                  else applyFunc fd args `bindS` pred2bool)
        (find (\fd -> funcName fd == qnpre) (nfConds ti))
 where
  qnpre = addSuffix qf "'nonfail"

-- Returns the precondition expression for a given operation
-- and its arguments (which are assumed to be variable indices).
-- Rename all local variables by adding the `freshvar` index to them.
preCondExpOf :: TransInfo -> QName -> [Int] -> State TransState BoolExp
preCondExpOf ti qf args =
  maybe (returnS bTrue)
        (\fd -> applyFunc fd args `bindS` pred2bool)
        (find (\fd -> funcName fd == qnpre) (preConds ti))
 where
  qnpre = addSuffix qf "'pre"

-- Returns the postcondition expression for a given operation
-- and its arguments (which are assumed to be variable indices).
-- Rename all local variables by adding `freshvar` to them and
-- return the new freshvar value.
postCondExpOf :: TransInfo -> QName -> [Int] -> State TransState BoolExp
postCondExpOf ti qf args =
  maybe (returnS bTrue)
        (\fd -> applyFunc fd args `bindS` pred2bool)
        (find (\fd -> funcName fd == qnpost) (postConds ti))
 where
  qnpost = addSuffix qf "'post"


-- Applies a function declaration on a list of arguments,
-- which are assumed to be variable indices, and returns
-- the renamed body of the function declaration.
-- All local variables are renamed by adding `freshvar` to them.
-- Also the new fresh variable index is returned.
applyFunc :: TAFuncDecl -> [Int] -> State TransState TAExpr
applyFunc fdecl args s0 =
  let (ARule _ orgargs orgexp) = funcRule fdecl
      exp = rnmAllVars (renameRuleVar orgargs) orgexp
      s1  = s0 { freshVar = max (freshVar s0)
                                (maximum (0 : args ++ allVars exp) + 1) }
  in (applyArgs exp (drop (length orgargs) args), s1)
 where
  -- renaming function for variables in original rule:
  renameRuleVar orgargs r = maybe (r + freshVar s0)
                                  (args!!)
                                  (elemIndex r (map fst orgargs))

  applyArgs e [] = e
  applyArgs e (v:vs) =
    -- simple hack for eta-expansion since the type annotations are not used:
    -- TODO: compute correct type annotations!!! (required for overloaded nils)
    let e_v =  AComb failed FuncCall
                     (("Prelude","apply"),failed) [e, AVar failed v]
    in applyArgs e_v vs

-- Translates a Boolean FlatCurry expression into a Boolean formula.
-- Calls to user-defined functions are replaced by the first argument
-- (which might be true or false).
pred2bool :: TAExpr -> State TransState BoolExp
pred2bool exp = case exp of
  AVar _ i              -> returnS (BVar i)
  ALit _ l              -> returnS (lit2bool l)
  AComb _ _ (qf,_) args -> comb2bool qf (length args) args
  _                     -> returnS (BTerm (show exp) [])
 where
  comb2bool qf ar args
    | qf == pre "[]" && ar == 0
    = returnS (BTerm "as" [BTerm "nil" [], type2SMTExp (annExpr exp)])
    | qf == pre "not" && ar == 1
    = pred2bool (head args) `bindS` \barg -> returnS (Not barg)
    | qf == pre "null" && ar == 1
    = let arg = head args
          argtype = annExpr arg
      in pred2bool (head args) `bindS` \barg ->
         returnS (bEqu barg (BTerm "as" [BTerm "nil" [], type2SMTExp argtype]))
    | qf == pre "apply" && ar == 2 && isComb (head args)
    = -- "defunctionalization": if the first argument is a
      -- combination, append the second argument to its arguments
      mapS pred2bool args `bindS` \bargs ->
      case bargs of
        [BTerm bn bas, barg2] -> returnS (BTerm bn (bas++[barg2]))
        _ -> returnS (BTerm (show exp) []) -- no translation possible
    | otherwise
    = mapS pred2bool args `bindS` \bargs ->
      returnS (BTerm (transOpName qf) bargs)

normalizeArgs :: [TAExpr] -> State TransState ([(Int,TAExpr)],[TAExpr])
normalizeArgs [] = returnS ([],[])
normalizeArgs (e:es) = case e of
  AVar _ i -> normalizeArgs es `bindS` \ (bs,nes) ->
              returnS ((i,e):bs, e:nes)
  _        -> getS `bindS` \ts ->
              let fvar = freshVar ts
                  nts  = addVarTypes [(fvar,annExpr e)] (incFreshVarIndex ts)
              in putS nts `bindS_`
                 normalizeArgs es `bindS` \ (bs,nes) ->
                 returnS ((fvar,e):bs, AVar (annExpr e) fvar : nes)


-- Rename argument variables of constructor pattern
renamePatternVars :: TransState -> TABranchExpr -> (TABranchExpr,TransState)
renamePatternVars pts (ABranch p e) =
  if isConsPattern p
    then let args = map fst (patArgs p)
             minarg = minimum (0 : args)
             maxarg = maximum (0 : args)
             fv = freshVar pts
             rnm i = if i `elem` args then i - minarg + fv else i
             nargs = map (\ (v,t) -> (rnm v,t)) (patArgs p)
         in (ABranch (updPatArgs (map (\ (v,t) -> (rnm v,t))) p)
                     (rnmAllVars rnm e),
             pts { freshVar = fv + maxarg - minarg + 1
                 , varTypes = nargs ++ varTypes pts })
    else (ABranch p e, pts)


-- Adds a suffix to some qualified name:
addSuffix :: QName -> String -> QName
addSuffix (mn,fn) s = (mn, fn ++ s)

---------------------------------------------------------------------------
-- Calls the SMT solver to check whether an assertion implies some
-- (pre/post) condition.
checkImplicationWithSMT :: Options -> IORef VState -> [(Int,TypeExpr)]
                        -> BoolExp -> BoolExp -> BoolExp -> IO (Maybe Bool)
checkImplicationWithSMT opts vstref vartypes assertion impbindings imp = do
  let smt = unlines
              [ "; Free variables:"
              , typedVars2SMT vartypes
              , "; Boolean formula of assertion (known properties):"
              , showBoolExp (assertSMT assertion)
              , ""
              , "; Bindings of implication:"
              , showBoolExp (assertSMT impbindings)
              , ""
              , "; Assert negated implication:"
              , showBoolExp (assertSMT (Not imp))
              , ""
              , "; check satisfiability:"
              , "(check-sat)"
              , "; if unsat, the implication is valid"
              ]
  let allsymbols = allSymbolsOfBE (Conj [assertion, impbindings, imp])
      allqsymbols = catMaybes (map untransOpName allsymbols)
  unless (null allqsymbols) $ printWhenIntermediate opts $
    "Translating operations into SMT: " ++
    unwords (map showQName allqsymbols)
  smtfuncs   <- funcs2SMT vstref allqsymbols
  smtprelude <- readFile (packagePath </> "include" </> "Prelude.smt")
  let smtinput = smtprelude ++ smtfuncs ++ smt
  printWhenIntermediate opts $ unlines ["SMT SCRIPT:", line, smtinput, line]
  printWhenIntermediate opts $ "CALLING Z3..."
  (ecode,out,err) <- evalCmd "z3" ["-smt2", "-in", "-T:5"] smtinput
  when (ecode>0) $ printWhenIntermediate opts $ "EXIT CODE: " ++ show ecode
  printWhenIntermediate opts $ "RESULT:\n" ++ out
  unless (null err) $ printWhenIntermediate opts $ "ERROR:\n" ++ err
  let pcvalid = let ls = lines out in not (null ls) && head ls == "unsat"
  return (if ecode>0 then Nothing else Just pcvalid)
 where
  line = take 78 (repeat '-')

-- Operations axiomatized by specific smt scripts (no longer necessary
-- since these scripts are now automatically generated by Curry2SMT.funcs2SMT).
-- However, for future work, it might be reasonable to cache these scripts
-- for faster contract checking.
axiomatizedOps :: [String]
axiomatizedOps = ["Prelude_null","Prelude_take","Prelude_length"]

---------------------------------------------------------------------------
-- Translates a list of type variables to SMT declarations:
typedVars2SMT :: [(Int,TypeExpr)] -> String
typedVars2SMT tvars = unlines (map tvar2SMT tvars)
 where
  tvar2SMT (i,te) = withBracket $ unwords
    ["declare-const", smtBE (BVar i), smtBE (type2SMTExp te)]

---------------------------------------------------------------------------
-- Auxiliaries:

--- Checks whether a file exists in one of the directories on the PATH.
fileInPath :: String -> IO Bool
fileInPath file = do
  path <- getEnviron "PATH"
  dirs <- return $ splitOn ":" path
  (liftIO (any id)) $ mapIO (doesFileExist . (</> file)) dirs

--- Tests whether the given branches of a case expressions
--- are a Boolean case distinction.
--- If yes, the expressions of the `False` and `True` branch
--- are returned.
testBoolCase :: [TABranchExpr] -> Maybe (TAExpr,TAExpr)
testBoolCase brs =
  if length brs /= 2 then Nothing
                     else case (brs!!0, brs!!1) of
    (ABranch (APattern _ (c1,_) _) e1, ABranch (APattern _ (c2,_) _) e2) ->
      if c1 == pre "False" && c2 == pre "True"  then Just (e1,e2) else
      if c1 == pre "True"  && c2 == pre "False" then Just (e2,e1) else Nothing
    _ -> Nothing

---------------------------------------------------------------------------

{-

Still to be done:

- translate datatypes (with test functions!)
- translate higher-order
- consider encapsulated search
- consider predefined functions, e.g.:
  fail'nonfail = False
  div'nonfail m n = n/=0

-}