module Language.Haskell.Names.ScopeUtils where

import Control.Applicative
import Control.Arrow
import qualified Data.Set as Set
import Data.Monoid
import Data.Lens.Common
import Language.Haskell.Names.Types
import Language.Haskell.Names.SyntaxUtils
import Language.Haskell.Exts.Annotated
import qualified Language.Haskell.Names.GlobalSymbolTable as Global
import Distribution.Package (PackageId)

scopeError :: Functor f => Error l -> f l -> f (Scoped l)
scopeError e f = Scoped (ScopeError e) <$> f

none :: l -> Scoped l
none = Scoped None

binder :: l -> Scoped l
binder = Scoped Binder

noScope :: (Annotated a) => a l -> a (Scoped l)
noScope = fmap none

sv_parent :: SymValueInfo n -> Maybe n
sv_parent (SymSelector { sv_typeName = n }) = Just n
sv_parent (SymConstructor { sv_typeName = n }) = Just n
sv_parent (SymMethod { sv_className = n }) = Just n
sv_parent _ = Nothing

-- | Annotate all local symbols with the package name and version
qualifySymbols :: PackageId -> Symbols -> Symbols
qualifySymbols pkg (Symbols vals tys) =
  Symbols
    (Set.map (fmap qualify) vals)
    (Set.map (fmap qualify) tys)
  where
    qualify (OrigName Nothing gname) =
      OrigName (Just pkg) gname
    qualify orig = orig

computeSymbolTable
  :: Bool
  -> ModuleName l
  -> Symbols
  -> Global.Table
computeSymbolTable qual (ModuleName _ mod) syms =
  Global.fromLists $
    if qual
      then renamed
      else renamed <> unqualified
  where
    vs = Set.toList $ syms^.valSyms
    ts = Set.toList $ syms^.tySyms
    renamed = renameSyms mod
    unqualified = renameSyms ""
    renameSyms mod = (map (rename mod) vs, map (rename mod) ts)
    rename :: HasOrigName i => ModuleNameS -> i OrigName -> (GName, i OrigName)
    rename m v =
      let OrigName _pkg (GName _ n) = origName v
      in (GName m n, v)

resolveCName
  :: Symbols
  -> OrigName
  -> (CName l -> Error l) -- ^ error for "not found" condition
  -> CName l
  -> (CName (Scoped l), Symbols)
resolveCName syms parent notFound cn =
  let
    vs =
      [ info
      | info <- Set.toList $ syms^.valSyms
      , let GName _ name = origGName $ sv_origName info
      , nameToString (unCName cn) == name
      , Just p <- return $ sv_parent info
      , p == parent
      ]
  in
    case vs of
      [] -> (scopeError (notFound cn) cn, mempty)
      [i] -> (Scoped (GlobalValue i) <$> cn, mkVal i)
      _ -> (scopeError (EInternal "resolveCName") cn, mempty)

resolveCNames
  :: Symbols
  -> OrigName
  -> (CName l -> Error l) -- ^ error for "not found" condition
  -> [CName l]
  -> ([CName (Scoped l)], Symbols)
resolveCNames syms orig notFound =
  second mconcat . unzip . map (resolveCName syms orig notFound)
