{-# LANGUAGE CPP #-}
{-# LANGUAGE PackageImports #-}
module DHC
  ( parseModule, AstF(..), Ast(..), Clay(..), Type(..)
  , inferType, parseDefs, lexOffside
  , arityFromType, hsToAst, liftLambdas
  ) where
import Control.Arrow
import Control.Monad
#ifdef __HASTE__
import "mtl" Control.Monad.State
#else
import Control.Monad.Reader
import Control.Monad.State
import qualified Data.ByteString.Char8 as B
import Data.ByteString.Short (ShortByteString, toShort)
#endif
import Data.Char
import Data.List
import qualified Data.Map.Strict as M
import Data.Map.Strict (Map)
import Data.Maybe
import Text.Parsec hiding (State)

import Ast
import Boost

sbs :: String -> ShortByteString
#ifdef __HASTE__
sbs = id
type ShortByteString = String
#else
sbs = toShort . B.pack
#endif

data LayoutState = IndentAgain Int | LineStart | LineMiddle | AwaitBrace | Boilerplate deriving (Eq, Show)

-- | For some reason (too much backtracking + strict evaluation somewhere?)
-- quasiquotation parsing repeatedly visits the same quasiquoted code.
-- We use a cache so we only compile code once.
type QQCache = Map (String, String) (Either String String)
type QQuoter = String -> String -> Either String String
type QQMonad = State (QQuoter, QQCache)
type Parser = ParsecT String (LayoutState, [Int]) QQMonad

program :: Parser Clay
program = do
  filler
  r <- toplevels
  eof
  pure r

data Associativity = LAssoc | RAssoc | NAssoc deriving (Eq, Show)

standardFixities :: Map String (Associativity, Int)
standardFixities = M.fromList $ concatMap (f . words)
  [ "infixl 9 !!"
  , "infixr 9 ."
  , "infixr 8 ^ ^^ **"
  , "infixl 7 * / div mod rem quot"
  , "infixl 6 + -"
  , "infixr 5 : ++"
  , "infix 4 == /= < <= > >= elem notElem"
  , "infixr 3 &&"
  , "infixr 2 ||"
  , "infixl 1 >> >>="
  , "infixr 0 $ $! seq"
  ]
  where
    f (assoc:prec:ops) = flip (,) (parseAssoc assoc, read prec) <$> ops
    f _ = undefined
    parseAssoc "infix"  = NAssoc
    parseAssoc "infixl" = LAssoc
    parseAssoc "infixr" = RAssoc
    parseAssoc _ = error "BUG! bad associativity"

fixity :: String -> (Associativity, Int)
fixity o = fromMaybe (LAssoc, 9) $ M.lookup o standardFixities

data Clay = Clay
  -- Public and secret functions are accompanied by a list of their
  -- arguments types and a program for decoding them from the heap.
  { publics :: [(String, [(Type, Ast)])]
  , secrets :: [(String, [(Type, Ast)])]
  , stores :: [(String, Type)]
  , funTypes :: Map String QualType
  , supers :: [(String, Ast)]
  , genDecls :: [(String, Type)]
  , datas :: [(String, (Maybe (Int, Int), Type))]
  , classes :: [(String, (Type, [(String, String)]))]
  } deriving Show

addSuper :: (String, Ast) -> Clay -> Clay
addSuper sc p = p { supers = sc:supers p }

addData :: [(String, (Maybe (Int, Int), Type))] -> Clay -> Clay
addData xs p = p { datas = xs ++ datas p }

addClass :: [(String, (Type, [(String, String)]))] -> Clay -> Clay
addClass xs p = p { classes = xs ++ classes p }

addGenDecl :: [(String, Type)] -> Clay -> Clay
addGenDecl xs p = p { genDecls = xs ++ genDecls p }

toplevels :: Parser Clay
toplevels = foldl' (flip ($)) (Clay [] [] [] M.empty [] [] [] []) <$> topDecls where
  topDecls = between (want "{") (want "}") (topDecl `sepBy` want ";")
  topDecl
      = (want "data" >> simpleType)
    <|> (want "class" >> classDecl)
    <|> genDecl
    <|> sc
    <|> pure id
  classDecl = do
    s <- con
    t <- tyVar
    void $ want "where"
    ms <- between (want "{") (want "}") $ cDecl `sepBy` want ";"
    pure $ addClass $ second (flip (,) [(s, t)]) <$> ms
  cDecl = do
    v <- var
    void $ want "::"
    t <- typeExpr
    pure (v, t)
  genDecl = try $ do
    v <- var
    void $ want "::"
    t <- typeExpr
    pure $ addGenDecl [(v, t)]
  simpleType = do
    s <- con
    args <- many tyVar
    void $ want "="
    let
      t = foldl' TApp (TC s) $ GV <$> args
      typeCon = do
        c <- con
        ts <- many atype
        pure (c, foldr (:->) t ts)
    typeCons <- typeCon `sepBy1` want "|"
    pure $ addData [(c, (Just (i, arityFromType typ), typ))
      | (i, (c, typ)) <- zip [0..] typeCons]
  typeExpr = foldr1 (:->) <$> btype `sepBy1` want "->"
  btype = foldl1' TApp <$> many1 atype
  -- Unsupported: [] (->) (,{,}) constructors.
  atype = (TC <$> con)
    <|> (GV <$> tyVar)
    <|> (TApp (TC "[]") <$> between (want "[") (want "]") typeExpr)
    <|> (parenType <$> between (want "(") (want ")") (typeExpr `sepBy` want ","))
  parenType [x] = x
  parenType xs  = foldr1 TApp $ TC "()":xs
  sc = try (do
    (fun:args) <- funlhs
    void $ want "="
    x <- expr
    pure $ addSuper (fun, if null args then x else Ast $ Lam args x))
  funlhs = scOp <|> many1 var
  scOp = try $ do
    l <- var
    op <- varSym
    r <- var
    pure [op, l, r]
  expr = caseExpr <|> letExpr <|> doExpr <|> bin 0 False
  bin 10 _ = molecule
  bin prec isR = rec False =<< bin (prec + 1) False where
    rec isL m = (try $ do
      o <- varSym <|> between (want "`") (want "`") var
      let (a, p) = fixity o
      when (p /= prec) $ fail ""
      case a of
        LAssoc -> do
          when isR $ fail "same precedence, mixed associativity"
          n <- bin (prec + 1) False
          rec True $ Ast $ Ast (Ast (Var o) :@ m) :@ n
        NAssoc -> do
          n <- bin (prec + 1) False
          pure $ Ast $ Ast (Ast (Var o) :@ m) :@ n
        RAssoc -> do
          when isL $ fail "same precedence, mixed associativity"
          n <- bin prec True
          pure $ Ast $ Ast (Ast (Var o) :@ m) :@ n
      ) <|> pure m
  letDefn = do
    (fun:args) <- funlhs
    void $ want "="
    ast <- expr
    pure (fun, if null args then ast else Ast $ Lam args ast)
  doExpr = do
    void $ want "do"
    ss <- between (want "{") (want "}") $ stmt `sepBy` want ";"
    case ss of
      [] -> fail "empty do block"
      ((mv, x):t) -> desugarDo x mv t
  desugarDo x Nothing [] = pure x
  desugarDo _ _ [] = fail "do block ends with (<-) statement"
  desugarDo x mv ((mv1, x1):rest) = do
    body <- desugarDo x1 mv1 rest
    pure $ Ast $ Ast (Ast (Var ">>=") :@ x) :@ Ast (Lam [fromMaybe "_" mv] body)
  stmt = do
    v <- expr
    lArrStmt v <|> pure (Nothing, v)
  lArrStmt v = want "<-" >> case v of
    Ast (Var s) -> do
      x <- expr
      pure (Just s, x)
    _ -> fail "want variable on left of (<-)"
  letExpr = do
    ds <- between (want "let") (want "in") $
      between (want "{") (want "}") $ letDefn `sepBy` want ";"
    Ast . Let ds <$> expr
  caseExpr = do
    x <- between (want "case") (want "of") expr
    as <- catMaybes <$> between (want "{") (want "}") (alt `sepBy` want ";")
    when (null as) $ fail "empty case"
    pure $ Ast $ Cas x as
  alt = try (do
    p <- expr
    void $ want "->"
    x <- expr
    pure $ Just (p, x)) <|> pure Nothing
  -- TODO: Introduce patterns to deal with _.
  lambda = fmap Ast $ Lam <$> between (want "\\") (want "->") (many1 (var <|> want "_")) <*> expr
  molecule = lambda <|> foldl1' ((Ast .) . (:@)) <$> many1 atom
  atom = tup <|> qvar
    <|> (Ast . Var <$> want "_")
    <|> (Ast . Var <$> var)
    <|> (Ast . Var <$> con)
    <|> num <|> str <|> lis <|> enumLis
  tup = try $ do
    xs <- between (want "(") (want ")") $ expr `sepBy` want ","
    pure $ case xs of  -- Abuse Pack to represent tuples.
      [] -> Ast $ Pack 0 0
      [x] -> x
      _ -> foldl' ((Ast .) . (:@)) (Ast $ Pack 0 $ length xs) xs
  enumLis = try $ between (want "[") (want "]") $ do
    a <- expr
    void $ want ".."
    b <- expr
    pure $ Ast $ Ast (Ast (Var "enumFromTo") :@ a) :@ b
  lis = try $ do
    items <- between (want "[") (want "]") $ expr `sepBy` want ","
    pure $ foldr (\a b -> Ast (Ast (Ast (Var ":") :@ a) :@ b)) (Ast $ Var "[]") items
  splitDot s = second tail $ splitAt (fromJust $ elemIndex '.' s) s
  qvar = try $ do
    (t, s) <- tok
    when (t /= LexQual) $ fail ""
    pure $ Ast $ uncurry Qual $ splitDot s
  num = try $ do
    (t, s) <- tok
    when (t /= LexNumber) $ fail ""
    pure $ Ast $ I $ read s
  str = try $ do
    (t, s) <- tok
    when (t /= LexString) $ fail ""
    pure $ Ast $ S $ sbs s
  con = try $ do
    (t, s) <- tok
    when (t /= LexCon) $ fail ""
    pure s
  tyVar = varId

varId :: Parser String
varId = try $ do
  (t, s) <- tok
  when (t /= LexVar) $ fail ""
  pure s

varSym :: Parser String
varSym = do
  (t, s) <- tok
  when (t /= LexVarSym) $ fail ""
  pure s

var :: Parser String
var = varId <|> (try $ between (want "(") (want ")") varSym)

reservedIds :: [String]
reservedIds = words "class data default deriving do else foreign if import in infix infixl infixr instance let module newtype of then type where _"

reservedOps :: [String]
reservedOps = ["..", "::", "=", "|", "<-", "->", "=>"]

want :: String -> Parser String
want t = expect <|> autoCloseBrace where
  autoCloseBrace = if t /= "}" then fail "" else do
    (ty, x) <- lookAhead tok
    if ty == LexSpecial && x == ")" || x == "]" then do
      (st, is) <- getState
      case is of
        (m:ms) | m /= 0 -> do
          putState (st, ms)
          pure "}"
        _ -> fail "missing }"
    else fail "missing }"
  expect = try $ do
    (ty, s) <- tok
    unless (ty /= LexString && s == t) $ fail $ "expected " ++ t
    pure s

data LexemeType = LexString | LexNumber | LexReserved | LexVar | LexCon | LexSpecial | LexVarSym | LexQual | LexEOF deriving (Eq, Show)
type Lexeme = (LexemeType, String)

-- | Layout-aware lexer.
-- See https://www.haskell.org/onlinereport/haskell2010/haskellch10.html
tok :: Parser Lexeme
tok = do
  filler
  (st, is) <- getState
  let
    autoContinueBrace n = case is of
      (m : _)  | m == n -> pure (LexSpecial, ";")
      (m : ms) | n < m -> do
        putState (IndentAgain n, ms)
        pure (LexSpecial, "}")
      _ -> rawTok
    explicitBrace = try $ do
      r <- rawTok
      when (r /= (LexSpecial, "{")) $ fail "bad indentation"
      putState (LineMiddle, 0:is)
      pure r
    end = do
      eof
      case is of
        0:_ -> fail "unmatched '{'"
        [] -> pure (LexEOF, "")
        _:ms -> do
          putState (st, ms)
          pure (LexSpecial, "}")
  end <|> case st of
    IndentAgain col -> do
      putState (LineMiddle, is)
      autoContinueBrace col
    LineStart -> do
      col <- sourceColumn <$> getPosition
      putState (LineMiddle, is)
      autoContinueBrace col
    AwaitBrace -> explicitBrace <|> do
      n <- sourceColumn <$> getPosition
      case is of
        (m : _) | n > m -> do
          putState (LineMiddle, n : is)
          pure (LexSpecial, "{")
        [] | n > 0 -> do
          putState (LineMiddle, [n])
          pure (LexSpecial, "{")
        -- Empty blocks unsupported (see Note 2 in above link).
        _ -> fail "TODO"
    _ -> do
      r <- rawTok
      when (r == (LexSpecial, "}")) $ case is of
        (0 : _) -> modifyState $ second tail
        _ -> fail "unmatched }"
      pure r

rawTok :: Parser Lexeme
rawTok = do
  r <- oxford <|> symbol <|> qId <|> num <|> special <|> str
  pure r
  where
  oxford = do
    q <- try $ between (char '[') (char '|') $ many alphaNum
    s <- oxfordClose <|> more
    (f, cache) <- get
    answer <- case M.lookup (q, s) cache of
      Nothing -> do
        let x = f q s
        put (f, M.insert (q, s) x cache)
        pure x
      Just x -> pure x
    either (fail . ("quasiquotation: " ++)) (pure . (,) LexString) answer
    where
    oxfordClose = try (string "|]") >> pure ""
    more = do
      s <- innerOxford <|> (pure <$> anyChar)
      (s ++) <$> (oxfordClose <|> more)
    innerOxford = do
      q <- try $ between (char '[') (char '|') $ many alphaNum
      s <- oxfordClose <|> more
      pure $ '[':q ++ ('|':s) ++ "|]"
  lowId = do
    s <- (:) <$> (lower <|> char '_') <*> many (alphaNum <|> oneOf "_'")
    when (s `elem` ["let", "where", "do", "of"]) $ do
      (_, is) <- getState
      putState (AwaitBrace, is)
    pure (if s `elem` reservedIds then LexReserved else LexVar, s)
  uppId = do
    s <- (:) <$> upper <*> many (alphaNum <|> oneOf "_'")
    pure (LexCon, s)
  qId = do
    r@(_, m) <- lowId <|> uppId
    (try $ do
      void $ char '.'
      (_, v) <- lowId <|> uppId
      pure (LexQual, m ++ '.':v)) <|> pure r
  num = do
    s <- many1 digit
    pure (LexNumber, s)
  special = (,) LexSpecial <$> foldl1' (<|>) (string . pure <$> "(),;[]`{}")
  symbol = do
    s <- many1 (oneOf "!#$%&*+./<=>?@\\^|-~:")
    pure (if s `elem` reservedOps then LexReserved else LexVarSym, s)
  str = do
    void $ char '"'
    s <- many $ (char '\\' >> escapes) <|> noneOf "\""
    void $ char '"'
    pure (LexString, s)
  escapes = foldl1' (<|>)
    [ char '\\' >> pure '\\'
    , char '"' >> pure '"'
    , char 'n' >> pure '\n'
    ]

filler :: Parser ()
filler = void $ many $ void (char ' ') <|> nl <|> com
  where
  hsNewline = (char '\r' >> optional (char '\n')) <|> void (oneOf "\n\f")
  com = do
    void $ between (try $ string "--") hsNewline $ many $ noneOf "\r\n\f"
    (st, is) <- getState
    when (st == LineMiddle) $ putState (LineStart, is)
  nl = do
    hsNewline
    (st, is) <- getState
    when (st == LineMiddle) $ putState (LineStart, is)

contract :: Parser Clay
contract = do
  ws <- option [] $ try $ want "public" >>
    (between (want "(") (want ")") $ var `sepBy` want ",")
  ss <- option [] $ try $ want "secret" >>
    (between (want "(") (want ")") $ var `sepBy` want ",")
  ps <- option [] $ try $ want "store" >>
    (between (want "(") (want ")") $ var `sepBy` want ",")
  putState (AwaitBrace, [])
  p <- toplevels
  when (isNothing $ mapM (`lookup` supers p) ws) $ fail "bad publics"
  when (isNothing $ mapM (`lookup` supers p) ss) $ fail "bad secrets"
  let
    storeCons s
      | Just ty <- lookup s $ genDecls p = (s, ty)
      | otherwise = (s, TC "Store" `TApp` TV ('@':s))
    withNulls = (`zip` repeat [])
  pure p { publics = withNulls ws, secrets = withNulls ss, stores = storeCons <$> ps }

qParse :: Parser a
  -> (LayoutState, [Int])
  -> String
  -> String
  -> Either ParseError a
qParse a b c d = evalState (runParserT a b c d) (justHere, M.empty)

justHere :: QQuoter
justHere "here" s = Right s
justHere _ _ = Left "bad scheme"

lexOffside :: String -> Either ParseError [String]
lexOffside = fmap (fmap snd) <$> qParse tokUntilEOF (AwaitBrace, []) "" where
  tokUntilEOF = do
    t <- tok
    case fst t of
      LexEOF -> pure []
      _ -> (t:) <$> tokUntilEOF

parseDefs :: String -> Either ParseError Clay
parseDefs = qParse program (AwaitBrace, []) ""

parseModule :: String -> Either ParseError Clay
parseModule = qParse contract (Boilerplate, []) ""

-- The Constraints monad combines a State monad and an Either monad.
-- The state consists of the set of constraints and next integer available
-- for naming a free variable, and the contexts of each variable.
data ConState = ConState Int [(Type, Type)] (Map String [String])
data Constraints a = Constraints (ConState -> Either String (a, ConState))

buildConstraints :: Constraints a -> Either String (a, ConState)
buildConstraints (Constraints f) = f $ ConState 0 [] M.empty

instance Functor Constraints where fmap = liftM
instance Applicative Constraints where
  (<*>) = ap
  pure = return

instance Monad Constraints where
  Constraints c1 >>= fc2 = Constraints $ \cs -> case c1 cs of
    Left err -> Left err
    Right (r, cs2) -> let Constraints c2 = fc2 r in c2 cs2
  return a = Constraints $ \p -> Right (a, p)

newTV :: Constraints Type
newTV = Constraints $ \(ConState i cs m) -> Right (TV $ "_" ++ show i, ConState (i + 1) cs m)

addConstraint :: (Type, Type) -> Constraints ()
addConstraint c = Constraints $ \(ConState i cs m) -> Right ((), ConState i (c:cs) m)

addContext :: String -> String -> Constraints ()
addContext s x = Constraints $ \(ConState i cs m) -> Right ((), ConState i cs $ M.insertWith union x [s] m)

type Globals = Map String (Maybe (Int, Int), Type)
type QualType = (Type, [(String, String)])

-- | Gathers constraints.
-- Replaces overloaded methods with Placeholder.
-- Replaces data constructors with Pack.
-- For DFINITY, replaces `my.f` with `#preslot n` where n is the slot number
-- preloaded with the secret or public function `f`.
gather
  :: Clay
  -> Globals
  -> [(String, QualType)]
  -> Ast
  -> Constraints (AAst Type)
gather cl globs env (Ast ast) = case ast of
  I i -> pure $ AAst (TC "Int") $ I i
  S s -> pure $ AAst (TC "String") $ S s
  Pack m n -> do  -- Only tuples are pre`Pack`ed.
    xs <- replicateM n newTV
    let r = foldr1 TApp $ TC "()":xs
    pure $ AAst (foldr (:->) r xs) $ Pack m n
  Qual "my" f
    | Just n <- elemIndex f (fst <$> publics cl ++ secrets cl) -> rec env $ Ast (Ast (Var "#preslot") :@ Ast (I $ fromIntegral n))
    | otherwise -> bad $ "must be secret or public: " ++ f
  Var "_" -> do
    x <- newTV
    pure $ AAst x $ Var "_"
  Var v -> case lookup v env of
    Just qt  -> do
      (t1, qs1) <- instantiate qt
      pure $ foldl' ((AAst t1 .) . (:@)) (AAst t1 $ Var v) $ (\(a, b) -> AAst (TC $ "Dict-" ++ a) $ Placeholder a (TV b)) <$> qs1
    Nothing -> case M.lookup v methods of
      Just qt -> do
        (t1, [(_, x)]) <- instantiate qt
        pure $ AAst t1 $ Placeholder v $ TV x
      Nothing -> case M.lookup v globs of
        Just (ma, gt) -> flip AAst (maybe (Var v) (uncurry Pack) ma) . fst <$> instantiate (gt, [])
        Nothing       -> bad $ "undefined: " ++ v
  t :@ u -> do
    a@(AAst tt _) <- rec env t
    b@(AAst uu _) <- rec env u
    x <- newTV
    addConstraint (tt, uu :-> x)
    pure $ AAst x $ a :@ b
  Lam args u -> do
    ts <- mapM (const newTV) args
    a@(AAst tu _) <- rec ((zip (filter (/= "_") args) $ zip ts $ repeat []) ++ env) u
    pure $ AAst (foldr (:->) tu ts) $ Lam args a
  Cas e as -> do
    aste@(AAst te _) <- rec env e
    x <- newTV
    astas <- forM as $ \(p, a) -> do
      let
        varsOf (Ast (t :@ u)) = varsOf t ++ varsOf u
        varsOf (Ast (Var v)) | isLower (head v) = [v]
        varsOf _ = []
      when (varsOf p /= nub (varsOf p)) $ bad "multiple binding in pattern"
      envp <- forM (varsOf p) $ \s -> (,) s . flip (,) [] <$> newTV
      -- TODO: Check p is a pattern.
      astp@(AAst tp _) <- rec (envp ++ env) p
      addConstraint (te, tp)
      asta@(AAst ta _) <- rec (envp ++ env) a
      addConstraint (x, ta)
      pure (astp, asta)
    pure $ AAst x $ Cas aste astas
  Let ds body -> do
    es <- forM (fst <$> ds) $ \s -> (,) s <$> newTV
    let envLet = (second (flip (,) []) <$> es) ++ env
    ts <- forM (snd <$> ds) $ rec envLet
    mapM_ addConstraint $ zip (snd <$> es) (afst <$> ts)
    body1@(AAst t _) <- rec envLet body
    pure $ AAst t $ Let (zip (fst <$> ds) ts) body1
  _ -> fail $ "BUG! unhandled: " ++ show ast
  where
    rec = gather cl globs
    bad = Constraints . const . Left
    afst (AAst t _) = t

-- | Instantiate generalized variables.
-- Returns type where all generalized variables have been instantiated along
-- with the list of type constraints where each generalized variable has
-- been instantiated with the same generated names.
instantiate :: QualType -> Constraints (Type, [(String, String)])
instantiate (ty, qs) = do
  (gvmap, result) <- f [] ty
  let qInstances = second (getVar gvmap) <$> qs
  forM_ qInstances $ uncurry addContext
  pure (result, qInstances)
  where
  getVar m v = x where Just (TV x) = lookup v m
  f m (GV s) | Just t <- lookup s m = pure (m, t)
             | otherwise = do
               x <- newTV
               pure ((s, x):m, x)
  f m (t :-> u) = do
    (m1, t') <- f m t
    (m2, u') <- f m1 u
    pure $ (m2, t' :-> u')
  f m (t `TApp` u) = do
    (m1, t') <- f m t
    (m2, u') <- f m1 u
    pure $ (m2, t' `TApp` u')
  f m t = pure (m, t)

generalize
  :: Solution
  -> (String, AAst Type)
  -> (String, (QualType, Ast))
generalize (soln, ctx) (fun, a0@(AAst t0 _)) = (fun, (qt, a1)) where
  qt@(_, qs) = runState (generalize' ctx $ typeSolve soln t0) []
  -- TODO: Here, and elsewhere: need to sort qs?
  dsoln = zip qs $ ("#d" ++) . show <$> [(0::Int)..]
  -- TODO: May be useful to preserve type annotations?
  a1 = dictSolve dsoln soln ast
  dvars = snd <$> dsoln
  ast = case deAnn a0 of
    Ast (Lam ss body) -> Ast $ Lam (dvars ++ ss) $ expandFun body
    body -> Ast $ Lam dvars $ expandFun body
  -- TODO: Take shadowing into account.
  expandFun
    | null dvars = id
    | otherwise  = ffix $ \h (Ast a) -> Ast $ case a of
      Var v | v == fun -> foldl' (\x d -> (Ast x :@ Ast (Var d))) a dvars
      _ -> h a

-- Replaces e.g. `TV x` with `GV x` and adds its constraints
-- (e.g. Eq x, Monad x) to the common pool.
generalize' :: Map String [String] -> Type -> State [(String, String)] Type
generalize' ctx ty = case ty of
  TV s -> do
    case M.lookup s ctx of
      Just cs -> modify' $ union $ flip (,) s <$> cs
      Nothing -> pure ()
    pure $ GV s
  u :-> v  -> (:->) <$> generalize' ctx u <*> generalize' ctx v
  TApp u v -> TApp  <$> generalize' ctx u <*> generalize' ctx v
  _        -> pure ty

methods :: Map String (Type, [(String, String)])
methods = M.fromList
  [ ("==", (a :-> a :-> TC "Bool", [("Eq", "a")]))
  , (">>=", (TApp m a :-> (a :-> TApp m b)  :-> TApp m b, [("Monad", "m")]))
  , ("pure", (a :-> TApp m a, [("Monad", "m")]))
  -- Generates call_indirect ops.
  , ("callSlot", (TC "I32" :-> a :-> TApp (TC "IO") (TC "()"), [("Message", "a")]))
  , ("set", (TApp (TC "Store") a :-> a :-> io (TC "()"), [("Storage", "a")]))
  , ("get", (TApp (TC "Store") a :-> io a, [("Storage", "a")]))
  ] where
    a = GV "a"
    b = GV "b"
    m = GV "m"
    io = TApp (TC "IO")

dictSolve :: [((String, String), String)] -> Map String Type -> Ast -> Ast
dictSolve dsoln soln (Ast ast) = case ast of
  u :@ v  -> Ast $ rec u :@ rec v
  Lam ss a -> Ast $ Lam ss $ rec a
  Cas e alts -> Ast $ Cas (rec e) $ (id *** rec) <$> alts
  Placeholder ">>=" t -> aVar "snd" @@ rec (Ast $ Placeholder "Monad" $ typeSolve soln t)
  Placeholder "pure" t -> aVar "fst" @@ rec (Ast $ Placeholder "Monad" $ typeSolve soln t)
  Placeholder "==" t -> rec $ Ast $ Placeholder "Eq" $ typeSolve soln t
  Placeholder "callSlot" t -> rec $ Ast $ Placeholder "Message" $ typeSolve soln t
  -- A storage variable x compiles to a pair (#set-n, #get-n) where n is the
  -- global variable assigned to hold x.
  --   set x y = fst x (toAny y)
  Placeholder "set" t -> Ast $ Lam ["x", "y"] $ aVar "fst" @@ aVar "x" @@ (aVar "p3of4" @@ rec (Ast $ Placeholder "Storage" $ typeSolve soln t) @@ aVar "y")
  --   get x = snd x >>= pure . fromAny
  Placeholder "get" t -> Ast $ Lam ["x"] $ aVar "io_monad" @@ (aVar "snd" @@ aVar "x") @@ (aVar "." @@ aVar "io_pure" @@ (aVar "p4of4" @@ rec (Ast $ Placeholder "Storage" $ typeSolve soln t)))
  Placeholder d t -> case typeSolve soln t of
    TV v -> Ast $ Var $ fromMaybe (error $ "unsolvable: " ++ show (d, v)) $ lookup (d, v) dsoln
    u -> findInstance d u
  _       -> Ast ast
  where
    aVar = Ast . Var
    infixl 5 @@
    x @@ y = Ast $ x :@ y
    rec = dictSolve dsoln soln
    findInstance "Message" t = Ast . CallSlot tu $ (aVar "p3of4" @@) . findInstance "Storage" <$> tu
      where tu = either (error "want tuple") id (listFromTupleType t)
    findInstance "Eq" t = case t of
      TC "String"        -> aVar "String-=="
      TC "Int"           -> aVar "Int-=="
      TApp (TC "[]") a -> aVar "list_eq_instance" @@ rec (Ast $ Placeholder "Eq" a)
      e -> error $ "BUG! no Eq for " ++ show e
    findInstance "Monad" t = case t of
      TC "Maybe" -> Ast (Pack 0 2) @@ aVar "maybe_pure" @@ aVar "maybe_monad"
      TC "IO" -> Ast (Pack 0 2) @@ aVar "io_pure" @@ aVar "io_monad"
      e -> error $ "BUG! no Monad for " ++ show e
    -- The "Storage" typeclass has four methods:
    --  1. toAnyRef
    --  2. fromAnyRef
    --  3. toUnboxed
    --  4. fromUnboxed
    -- For boxed types such as databufs, 1 and 2 are the same as 3 and 4.
    -- For unboxed types, such as integers, 1 encodes to a databuf, 2 decodes
    -- from a databuf, and 3 and 4 leave the input unchanged.
    findInstance "Storage" t = case t of
      TC "Databuf" -> boxy (aVar "#reduce") (aVar "#reduce")
      TC "String" -> boxy (aVar "." @@ aVar "#reduce" @@ aVar "toD") (aVar "." @@ aVar "#reduce" @@ aVar "fromD")
      TC "Port" -> boxy (aVar "#reduce") (aVar "#reduce")
      TC "Actor" -> boxy (aVar "#reduce") (aVar "#reduce")
      TC "Module" -> boxy (aVar "#reduce") (aVar "#reduce")
      TC "Int" -> Ast (Pack 0 4) @@ aVar "Int-toAny" @@ aVar "Int-fromAny" @@ aVar "#reduce" @@ aVar "#reduce"
      TC "Bool" -> Ast (Pack 0 4) @@ aVar "Bool-toAny" @@ aVar "Bool-fromAny" @@ aVar "Bool-toUnboxed" @@ aVar "Bool-fromUnboxed"
      TApp (TC "[]") a -> let
        ltai = aVar "list_to_any_instance" @@ rec (Ast $ Placeholder "Storage" a)
        lfai = aVar "list_from_any_instance" @@ rec (Ast $ Placeholder "Storage" a)
        in boxy ltai lfai
      TApp (TC "()") (TApp a b) -> let
        ptai = aVar "pair_to_any_instance" @@ rec (Ast $ Placeholder "Storage" a) @@ rec (Ast $ Placeholder "Storage" b)
        pfai = aVar "pair_from_any_instance" @@ rec (Ast $ Placeholder "Storage" a) @@ rec (Ast $ Placeholder "Storage" b)
        in boxy ptai pfai
      e -> error $ "BUG! no Storage for " ++ show e
      where boxy to from = Ast (Pack 0 4) @@ to @@ from @@ to @@ from
    findInstance d t = error $ "BUG! bad class: " ++ show (d, t)

typeSolve :: Map String Type -> Type -> Type
typeSolve soln t = case t of
  TApp a b      -> rec a `TApp` rec b
  a :-> b       -> rec a :-> rec b
  TV x          -> fromMaybe t $ M.lookup x soln
  _             -> t
  where rec = typeSolve soln

-- | The `propagateClasses` and `propagateClassTyCon` functions of
-- "Implementing type classes".
propagate :: [String] -> Type -> Either String [(String, [String])]
propagate [] _ = Right []
propagate cs (TV y) = Right [(y, cs)]
propagate cs t = concat <$> mapM propagateTyCon cs where
  propagateTyCon "Eq" = case t of
    TC "Int" -> Right []
    TC "String" -> Right []
    TApp (TC "[]") a -> propagate ["Eq"] a
    _ -> Left $ "no Eq instance: " ++ show t
  propagateTyCon "Monad" = case t of
    TC "Maybe" -> Right []
    TC "IO" -> Right []
    _ -> Left $ "no Monad instance: " ++ show t
  propagateTyCon "Storage" = case t of
    TApp (TC "()") (TApp a b) -> (++) <$> propagate ["Storage"] a <*> propagate ["Storage"] b
    TApp (TC "[]") a -> propagate ["Storage"] a
    TC s | elem s messageTypes -> Right []
    _ -> Left $ "no Storage instance: " ++ show t
  propagateTyCon "Message" =
    concat <$> (mapM (propagate ["Storage"]) =<< listFromTupleType t)
  propagateTyCon c = error $ "TODO: " ++ c

-- | Returns list of types from a tuple.
-- e.g. (String, Int) becomes [String, Int]
-- This should be trivial, but we represent tuples in a weird way!
listFromTupleType :: Type -> Either String [Type]
listFromTupleType ty = case ty of
  TC "()" -> Right []
  TApp (TC "()") rest -> weirdList rest
  _ -> Right [ty]
  where
  -- Tuples are represented oddly in our Type data structure.
  weirdList tup = case tup of
    TC _ -> Right [tup]
    TV _ -> Right [tup]
    TApp h@(TC _) rest -> (h:) <$> weirdList rest
    TApp h@(TV _) rest -> (h:) <$> weirdList rest
    _ -> Left $ "want tuple: " ++ show tup

type Solution = (Map String Type, Map String [String])

unify :: [(Type, Type)] -> Map String [String] -> Either String Solution
unify constraints ctx = execStateT (uni constraints) (M.empty, ctx)

refine :: [(Type, Type)] -> Solution -> Either String Solution
refine constraints soln = execStateT (uni constraints) soln

uni :: [(Type, Type)] -> StateT (Map String Type, Map String [String]) (Either String) ()
uni [] = do
  (tm, qm) <- get
  as <- forM (M.keys tm) $ follow . TV
  put (M.fromList $ zip (M.keys tm) as, qm)
uni ((GV _, _):_) = lift $ Left "BUG! generalized variable in constraint"
uni ((_, GV _):_) = lift $ Left "BUG! generalized variable in constraint"
uni ((lhs, rhs):cs) = do
  z <- (,) <$> follow lhs <*> follow rhs
  case z of
    (s, t) | s == t -> uni cs
    (TV x, TV y) -> do
      when (x /= y) $ do
        (tm, qm) <- get
        -- (Ideally should union by rank.)
        put (M.insert x (TV y) tm, case M.lookup x qm of
          Just q -> M.insert y q $ M.delete x qm
          _ -> qm)
      uni cs
    (TV x, t) -> do
      -- TODO: Test infinite type detection.
      if x `elem` freeTV t then lift . Left $ "infinite: " ++ x ++ " = " ++ show t
      else do
        -- The `instantiateTyvar` function of "Implementing type classes".
        (_, qm) <- get
        -- For example, Eq [a] propagates to Eq a, which we record.
        either (lift . Left) addQuals $ propagate (fromMaybe [] $ M.lookup x qm) t
        modify' $ first $ M.insert x t
        uni cs
    (s, t@(TV _)) -> uni $ (t, s):cs
    (TApp s1 s2, TApp t1 t2) -> uni $ (s1, t1):(s2, t2):cs
    (s1 :-> s2, t1 :-> t2) -> uni ((s1, t1):(s2, t2):cs)
    (s, t) -> lift . Left $ "mismatch: " ++ show s ++ " /= " ++ show t
  where addQuals = modify' . second . M.unionWith union . M.fromList

-- Galler-Fischer-esque Data.Map (path compression).
follow :: Type -> StateT (Map String Type, a) (Either String) Type
follow t = case t of
  TApp a b -> TApp <$> follow a <*> follow b
  a :-> b  -> (:->) <$> follow a <*> follow b
  TV x     -> do
    (tm, qm) <- get
    case M.lookup x tm of
      Just u -> do
        z <- follow u
        put (M.insert x z tm, qm)
        pure z
      Nothing -> pure $ TV x
  _        -> pure t
freeTV :: Type -> [String]
freeTV t = case t of
  TApp a b -> freeTV a ++ freeTV b
  a :-> b  -> freeTV a ++ freeTV b
  TV tv    -> [tv]
  _        -> []

arityFromType :: Type -> Int
arityFromType = f 0 where
  f acc (_ :-> r) = f (acc + 1) r
  f acc _ = acc

boostTypes :: Boost -> Map String (Maybe (Int, Int), Type)
boostTypes b = M.fromList $ second (((,) Nothing) . fst) <$> boostPrims b

hsToAst :: Boost -> QQuoter -> String -> Either String Clay
hsToAst boost qq prog = do
  cl <- showErr $ evalState (runParserT contract (Boilerplate, []) "" prog) (qq, M.empty)
  (inferred, storageCons) <- inferType boost cl
  let
    subbedDefs = (second expandCase <$>) . liftLambdas . (second snd <$>) $ inferred
    types = M.fromList $ second fst <$> inferred
    stripStore (TApp (TC "Store") t) = t
    stripStore _ = error "expect Store"
  pure cl
    { publics = addDecoders types . fst <$> publics cl
    , secrets = addDecoders types . fst <$> secrets cl
    , supers = subbedDefs
    , funTypes = types
    , stores = second (stripStore . typeSolve storageCons) <$> stores cl }
  where
  showErr = either (Left . show) Right

addDecoders :: (Map String QualType) -> String -> (String, [(Type, Ast)])
addDecoders types s = (s, addDec [] ty)
  where
  Just (ty, _) = M.lookup s types
  addDec acc t = case t of
    a :-> b -> addDec ((a, dictSolve [] M.empty $ aVar "p4of4" @@ Ast (Placeholder "Storage" a)) : acc) b
    TApp (TC "IO") (TC "()") -> reverse acc
    _ -> error $ "exported functions must return IO ()"
  aVar = Ast . Var
  infixl 5 @@
  x @@ y = Ast $ x :@ y

inferType
  :: Boost
  -> Clay
  -- Returns types of definitions and stores.
  -> Either String ([(String, (QualType, Ast))], Map String Type)
inferType boost cl = foldM inferMutual ([], M.empty) $ map (map (\k -> (k, fromJust $ lookup k ds))) sortedDefs where
  -- Groups of definitions, sorted in the order we should infer their types.
  sortedDefs = reverse $ scc (callees ds) $ fst <$> ds
  -- List notation is a special case in Haskell.
  -- This is "data [a] = [] | a : [a]" in spirit.
  listPresets = M.fromList
    [ ("[]", (Just (0, 0), TApp (TC "[]") a))
    , (":",  (Just (1, 2), a :-> TApp (TC "[]") a :-> TApp (TC "[]") a))
    ] where a = GV "a"
  globs = listPresets
    `M.union` M.fromList (datas preludeDefs)
    `M.union` M.fromList (datas cl)
    `M.union` boostTypes boost
    `M.union` M.fromList (second ((,) Nothing) <$> stores cl)
  Right preludeDefs = parseDefs $ boostPrelude boost
  ds = supers cl ++ supers preludeDefs
  inferMutual :: ([(String, (QualType, Ast))], Map String Type) -> [(String, Ast)] -> Either String ([(String, (QualType, Ast))], Map String Type)
  inferMutual (acc, accStorage) grp = do
    (typedAsts, ConState _ cs m) <- buildConstraints $ forM grp $ \(s, d) -> do
      t <- gather cl globs env d
      addConstraint (TV $ '*':s, annOf t)
      when (s == "main") $ addConstraint (TV $ '*':s, TApp (TC "IO") $ TC "()")
      case (s `lookup` genDecls cl) of
        Nothing -> pure ()
        Just gt -> do
          (ty, _) <- instantiate (gt, [])
          addConstraint (TV $ '*':s, ty)
      pure (s, t)
    initSol <- unify cs m
    sol@(solt, _) <- foldM (checkPubSecs cl) initSol (fst <$> grp)
    let storageCons = M.filterWithKey (\k _ -> head k == '@') solt
    -- TODO: Look for conflicting storage constraints.
    pure ((++ acc) $ generalize sol <$> typedAsts, accStorage `M.union` storageCons)
    where
      annOf (AAst a _) = a
      tvs = TV . ('*':) . fst <$> grp
      env = zip (fst <$> grp) (zip tvs $ repeat $ []) ++ map (second fst) acc

checkPubSecs :: Clay -> Solution -> String -> Either String Solution
checkPubSecs cl (soln, ctx) s
  | s /= "main" &&  -- Already handled.
      (s `elem` (fst <$> publics cl ++ secrets cl)) =
    -- Require `public` and `secret` functions to return IO ().
    refine [(retType t, TApp (TC "IO") (TC "()"))] (soln, ctx)
    -- TODO: Check no free variables are left, and
    -- propagate ["Storage"] succeeds (returns []) for each argument type.
  | otherwise = Right (soln, ctx)
  where
  Just t = M.lookup ('*':s) soln
  retType (_ :-> a) = retType a
  retType r = r

-- TODO: For finding strongly-connected components, there's no need to find
-- all dependencies. If a node has already been processed, we should avoid
-- finding all its dependencies again. We can do this by passing in a list of
-- nodes that have already been explored.
callees :: [(String, Ast)] -> String -> [String]
callees ds s = snd $ execState (go s) ([], []) where
  go :: String -> State ([String], [String]) ()
  go f = do
    (env, acc) <- get
    when (not $ elem f (env ++ acc) || M.member f methods) $ case lookup f ds of
      -- TODO: If we knew the primitives (functions implemented in wasm, such
      -- as `*`), then we could detect out-of-scope identifiers here.
      Nothing -> pure ()  -- error $ "not in scope: " ++ f
      Just d -> do
        put (env, f:acc)
        ast d
  ast (Ast d) = case d of
    x :@ y -> ast x >> ast y
    Lam ss t -> do
      env <- gets fst
      modify $ first (ss ++)
      ast t
      modify $ first (const env)
    Var v -> go v
    Cas x as -> do
      ast x
      forM_ as $ \(Ast p, e) -> do
        env <- gets fst
        modify $ first (caseVars p ++)
        ast e
        modify $ first (const env)
    Let as x -> do
      env <- gets fst
      modify $ first ((fst <$> as) ++)
      mapM_ ast $ snd <$> as
      ast x
      modify $ first (const env)
    _ -> pure ()

-- | Returns strongly connected components in topological order.
scc :: Eq a => (a -> [a]) -> [a] -> [[a]]
scc suc vs = foldl' (\cs v -> assign cs [] v : cs) [] $ reverse $ topo suc vs where
  assign cs c v | any (elem v) $ c:cs = c
                | otherwise           = foldl' (assign cs) (v:c) (suc v)

topo :: Eq a => (a -> [a]) -> [a] -> [a]
topo suc vs = fst $ foldl' visit ([], []) vs where
  visit (done, doing) v
    | v `elem` done || v `elem` doing = (done, doing)
    | otherwise = (\(xs, x:ys) -> (x:xs, ys)) $
      foldl' visit (done, v:doing) (suc v)

freeV :: [(String, Ast)] -> [(String, AAst [String])]
freeV scs = map f scs where
  f (d, Ast ast) = (d, g [] ast)
  g :: [String] -> AstF Ast -> AAst [String]
  g cand (Lam ss (Ast a)) = AAst (vs \\ ss) $ Lam ss a1 where
    a1@(AAst vs _) = g (union cand ss) a
  g cand (Ast x :@ Ast y) = AAst (xv `union` yv) $ x1 :@ y1 where
    x1@(AAst xv _) = g cand x
    y1@(AAst yv _) = g cand y
  g cand (Var v) | v `elem` cand = AAst [v] $ Var v
                 | otherwise     = AAst []  $ Var v
  g cand (Cas (Ast x) as) = AAst (foldl' union xv $ fst <$> as1) $ Cas x1 $ snd <$> as1 where
    x1@(AAst xv _) = g cand x
    as1 = map h as
    h (Ast p, Ast e) = (vs1, (g [] p, e1)) where
      e1@(AAst vs _) = g (cand `union` caseVars p) e
      vs1 = vs \\ caseVars p
  g cand (Let ds (Ast e)) = AAst (ev \\ binders) $ Let ds1 e1 where
    e1@(AAst ev _) = g (cand `union` binders) e
    binders = fst <$> ds
    ds1 = map h ds
    h (s, Ast x) = (s, g (cand `union` binders) x)
  g _ x = ffix (\h (Ast ast) -> AAst [] $ h ast) $ Ast x

caseVars :: AstF Ast -> [String]
caseVars (Var v) = [v]
caseVars (Ast x :@ Ast y) = caseVars x `union` caseVars y
caseVars _ = []

liftLambdas :: [(String, Ast)] -> [(String, Ast)]
liftLambdas scs = existingDefs ++ newDefs where
  (existingDefs, (_, newDefs)) = runState (mapM f $ freeV scs) ([], [])
  f (s, (AAst _ (Lam args body))) = do
    modify $ first $ const [s]
    body1 <- g body
    pure (s, Ast $ Lam args body1)
  f _ = error "bad top-level definition"
  genName :: State ([String], [(String, Ast)]) String
  genName = do
    (names, ys) <- get
    let
      n = head $ filter (`notElem` names) $
        (++ ('$':last names)) . show <$> [(0::Int)..]
    put (n:names, ys)
    pure n
  g (AAst _ (x :@ y)) = fmap Ast $ (:@) <$> g x <*> g y
  g (AAst _ (Let ds t)) = fmap Ast $ Let <$> mapM noLamb ds <*> g t where
    noLamb (name, (AAst fvs (Lam ss body))) = do
      n <- genName
      body1 <- g body
      modify $ second ((n, Ast $ Lam (fvs ++ ss) body1):)
      pure (name, foldl' ((Ast .) . (:@)) (Ast $ Var n) $ Ast . Var <$> fvs)
    noLamb (name, a) = (,) name <$> g a
  g (AAst fvs lam@(Lam _ _)) = do
    n <- genName
    g $ AAst fvs $ Let [(n, AAst fvs lam)] (AAst [n] $ Var n)
  g (AAst _ (Cas expr as)) =
    fmap Ast $ Cas <$> g expr <*> mapM (\(p, t) -> (,) <$> g p <*> g t) as
  g ann = pure $ deAnn ann

expandCase :: Ast -> Ast
expandCase = ffix $ \h (Ast ast) -> Ast $ case ast of
  Cas e alts -> dupCase (rec e) alts
  _ -> h ast
  where
    rec = expandCase
    dupCase e [a] = Cas e $ evalState (expandAlt Nothing [] a) 0
    dupCase e (a:as) = Cas e $ evalState (expandAlt (Just $ rec $ Ast $ Cas e as) [] a) 0
    dupCase _ _ = error "BUG! no case alternatives"

    -- TODO: Call `fromApList` only in last case alternative.
    expandAlt :: Maybe Ast -> [(Ast, Ast)] -> (Ast, Ast) -> State Int [(Ast, Ast)]
    expandAlt onFail deeper (p, a) = do
      case fromApList p of
        [Ast (Var _)] -> (:moreCases) . (,) p <$> g deeper a
        [Ast (S s)] -> do
          v <- genVar
          a1 <- g deeper a
          pure [(Ast $ Var v, Ast $ Cas (Ast (Ast (Ast (Var "String-==") :@ Ast (Var v)) :@ Ast (S s))) $ (Ast $ Pack 1 0, a1):moreCases)]
        [Ast (I n)] -> do
          v <- genVar
          a1 <- g deeper a
          pure [(Ast $ Var v, Ast $ Cas (Ast (Ast (Ast (Var "Int-==") :@ Ast (Var v)) :@ Ast (I n))) $ (Ast $ Pack 1 0, a1):maybe [] ((pure . (,) (Ast $ Pack 0 0))) onFail)]
        h@(Ast (Pack _ _)):xs -> (++ moreCases) <$> doPack [h] deeper xs a
        _ -> error $ "bad case: " ++ show p

      where
      moreCases = maybe [] ((pure . (,) (Ast $ Var "_"))) onFail
      doPack acc dpr [] body = (:moreCases) . (,) (foldl1 ((Ast .) . (:@)) acc) <$> g dpr body
      doPack acc dpr (h:rest) body = do
        gv <- Ast . Var <$> genVar
        case h of
          Ast (Var _) -> doPack (acc ++ [h]) dpr rest body
          _     -> doPack (acc ++ [gv]) (dpr ++ [(gv, h)]) rest body
      g [] body = pure body
      g ((v, w):rest) body = fmap Ast $ Cas v <$> expandAlt onFail rest (w, body)

    genVar = do
      n <- get
      put (n + 1)
      pure $ "c*" ++ show n

    fromApList :: Ast -> [Ast]
    fromApList (Ast (a :@ b)) = fromApList a ++ [b]
    fromApList a = [a]

messageTypes :: [String]
messageTypes = ["Databuf", "String", "Actor", "Module", "Port", "I32", "Int", "Bool"]
