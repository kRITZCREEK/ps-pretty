{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}
module Pretty where

import qualified Language.PureScript             as P
import           System.IO.UTF8                  (readUTF8File)
import           Text.PrettyPrint.ANSI.Leijen    hiding ((<$>))
import qualified Text.PrettyPrint.ANSI.Leijen    as PP
import qualified Text.PrettyPrint.Boxes as Box

moduleFromFile :: IO P.Module
moduleFromFile = do
  let path = "example/Pretty.purs"
  input <- readUTF8File path
  fmap snd $
    case P.parseModulesFromFiles id [(path, input)] of
      Right [m] -> pure m
      _ -> error "bam!"

tupledS :: [Doc] -> Doc
tupledS = encloseSep (lparen <+> empty) (empty <+> rparen) (comma <+> empty)

ppComment :: P.Comment -> Doc
ppComment comment = case comment of
  P.LineComment c -> "--" <> text c
  P.BlockComment c -> "{-" <> string c <> "-}"

ppIdent :: P.Ident -> Doc
ppIdent = text . P.runIdent

ppProperName :: P.ProperName a -> Doc
ppProperName = text . P.runProperName

ppModuleName :: P.ModuleName -> Doc
ppModuleName = text . P.runModuleName

ppTypeargument :: (String, Maybe P.Kind) -> Doc
ppTypeargument (s, kind) = case kind of
  Nothing -> text s
  Just k -> parens (text s <+> "::" <+> text (P.prettyPrintKind k))

ppDataConstructor :: (P.ProperName 'P.ConstructorName, [P.Type]) -> Doc
ppDataConstructor (cname, ts) =
  let
    types = init . P.prettyPrintType <$> ts
    prettyType t = align . cat . map text $ lines t
  in
    ppProperName cname <+> hsep (prettyType <$> types)

ppDeclarationRef :: P.DeclarationRef -> Doc
ppDeclarationRef dr = case dr of
  P.PositionedDeclarationRef _ [] d ->
    ppDeclarationRef d
  P.PositionedDeclarationRef _ cs d ->
    align $ vsep (ppComment <$> cs) PP.<$> ppDeclarationRef d
  P.TypeRef tn Nothing ->
    ppProperName tn <> "(..)"
  P.TypeRef tn (Just ctors) ->
    ppProperName tn <> tupledS (ppProperName <$> ctors)
  P.TypeOpRef i ->
    parens (ppIdent i)
  P.ValueRef i ->
    ppIdent i
  P.TypeClassRef pn ->
    "class" <+> ppProperName pn
  P.TypeInstanceRef i ->
    ppIdent i
  P.ModuleRef mn ->
    "module" <+> ppModuleName mn
  P.ProperRef s ->
    text s

ppDeclaration :: P.Declaration -> Doc
ppDeclaration declaration = case declaration of
  P.PositionedDeclaration _ [] d ->
    ppDeclaration d
  P.PositionedDeclaration _ cs d ->
    vsep (ppComment <$> cs) PP.<$> ppDeclaration d
  -- |
  -- A module import (module name, qualified/unqualified/hiding, optional "qualified as" name)
  -- TODO: also a boolean specifying whether the old `qualified` syntax was used, so a warning can be raised in desugaring (remove for 0.9)
  --
  -- ImportDeclaration ModuleName ImportDeclarationType (Maybe ModuleName) Bool
  P.ImportDeclaration mn (P.Explicit refs) qual _ ->
    "import" <+> ppModuleName mn <+> tupledS (ppDeclarationRef <$> refs) <> maybe empty (\q -> " as" <+> ppModuleName q) qual
  P.ImportDeclaration mn P.Implicit qual _ ->
    "import" <+> ppModuleName mn <> maybe empty (\q -> " as" <+> ppModuleName q) qual
  P.ImportDeclaration mn (P.Hiding refs) qual _ ->
    "import" <+> ppModuleName mn <+> "hiding" <+> tupledS (ppDeclarationRef <$> refs) <> maybe empty (\q -> " as" <+> ppModuleName q) qual
  -- |
  -- A data type declaration (data or newtype, name, arguments, data constructors)
  --
  -- DataDeclaration DataDeclType (ProperName 'TypeName) [(String, Maybe Kind)] [(ProperName 'ConstructorName, [Type])]
  P.DataDeclaration P.Newtype typeName arguments dtors ->
    "newtype" <+> ppProperName typeName <> (if null arguments then empty else space <> hsep (ppTypeargument <$> arguments))
    <+> equals <+> cat (ppDataConstructor <$> dtors)
  P.DataDeclaration P.Data typeName arguments dtors ->
    "data" <+> ppProperName typeName <+> hsep (ppTypeargument <$> arguments) PP.<$>
      indent 2 (encloseSep (equals <> space) empty "| " (ppDataConstructor <$> dtors))
  -- |
  -- A minimal mutually recursive set of data type declarations
  --
  -- DataBindingGroupDeclaration [Declaration]
  P.DataBindingGroupDeclaration decls ->
    "DataBindingsGroupDeclaration" <+> hang 2 (vsep (ppDeclaration <$> decls))
  -- |
  -- A type synonym declaration (name, arguments, type)
  --
  -- TypeSynonymDeclaration (ProperName 'TypeName) [(String, Maybe Kind)] Type
  P.TypeSynonymDeclaration typeName arguments type' ->
    "type" <+> ppProperName typeName <+> hsep (ppTypeargument <$> arguments) <+> equals <+>  ppType type'
  -- |
  -- A type declaration for a value (name, ty)
  --
  -- TypeDeclaration Ident Type
  P.TypeDeclaration i t ->
    ppIdent i <+> "::" <+> ppType t
  -- |
  -- A value declaration (name, top-level binders, optional guard, value)
  --
  -- ValueDeclaration Ident NameKind [Binder] (Either [(Guard, Expr)] Expr)
  P.ValueDeclaration i _ binders (Right expr) ->
    ppIdent i <+> hsep (text . P.prettyPrintBinder <$> binders) <+> equals <+> ppValue expr
  P.ValueDeclaration i _ binders (Left guards) ->
    ppIdent i <+> hsep (text . P.prettyPrintBinder <$> binders) PP.<$>
      indent 2 (encloseSep "| " empty "| " ((\(guard, expr) -> ppValue guard <+> equals <+> ppValue expr) <$> guards))
  -- |
  -- A minimal mutually recursive set of value declarations
  --
  -- BindingGroupDeclaration [(Ident, NameKind, Expr)]
  P.BindingGroupDeclaration _ ->
    "BindingGroupDeclaration"
  -- |
  -- A foreign import declaration (name, type)
  --
  -- ExternDeclaration Ident Type
  P.ExternDeclaration i type' ->
    "foreign import" <+> ppIdent i <+> "::" <+> ppType type'
  -- |
  -- A data type foreign import (name, kind)
  --
  -- ExternDataDeclaration (ProperName 'TypeName) Kind
  P.ExternDataDeclaration tn kind ->
    "foreign import data" <+> ppProperName tn <+> "::" <+> text (P.prettyPrintKind kind)
  -- |
  -- A fixity declaration (fixity data, operator name, value the operator is an alias for)
  --
  -- FixityDeclaration Fixity String (Maybe (Qualified FixityAlias))
  P.FixityDeclaration fixity operator (Just alias) ->
    ppFixity fixity
      <+> text (P.showQualified ppFixityAlias alias)
      <+> "as" <+> text operator
    where
      ppFixityAlias fa = case fa of
        P.AliasValue i -> P.runIdent i
        P.AliasConstructor cn -> P.runProperName cn
        P.AliasType tn -> P.runProperName tn
  -- |
  -- A type class declaration (name, argument, implies, member declarations)
  --
  -- TypeClassDeclaration (ProperName 'ClassName) [(String, Maybe Kind)] [Constraint] [Declaration]
  P.TypeClassDeclaration cn arguments constraints members ->
      (if null constraints
        then "class"
        else "class" <+> tupled (ppConstraint <$> constraints) <+> "<=")
      <+> ppProperName cn
      <+> cat (ppTypeargument <$> arguments)
      PP.<$>
        indent 2 (vsep (ppDeclaration <$> members))
  -- |
  -- A type instance declaration (name, dependencies, class name, instance types, member
  -- declarations)
  --
  -- TypeInstanceDeclaration Ident [Constraint] (Qualified (ProperName 'ClassName)) [Type] TypeInstanceBody
  P.TypeInstanceDeclaration i constraints cn types (P.ExplicitInstance body) ->
    "instance" <+> ppIdent i <+> "::"
      <> (if null constraints then empty else space <> tupled (ppConstraint <$> constraints) <+> "=>")
      <+> text (P.showQualified P.runProperName cn)
      <+> parens (vsep (ppType <$> types))
      <+> "where"
      PP.<$> indent 2
        (vsep (ppDeclaration <$> body))
  P.TypeInstanceDeclaration i _ cn types P.DerivedInstance ->
    "derive instance" <+> ppIdent i <+> "::"
      <+> text (P.showQualified P.runProperName cn)
      <+> parens (hsep (ppType <$> types))

ppValue :: P.Expr -> Doc
ppValue = text . init . Box.render . P.prettyPrintValue 9

ppType :: P.Type -> Doc
ppType = text . init . P.prettyPrintType

ppFixity :: P.Fixity -> Doc
ppFixity (P.Fixity a p) = text (P.showAssoc a) <+> integer p

ppConstraint :: P.Constraint -> Doc
ppConstraint (cn, tys) =
  text (P.showQualified P.runProperName cn) <+> hsep (ppType <$> tys)

ppModuleHeader :: P.ModuleName -> Maybe [P.DeclarationRef] -> Doc
ppModuleHeader mn Nothing = "module" <+> ppModuleName mn <+> "where"
ppModuleHeader mn (Just exps) =
  "module" <+> ppModuleName mn
  <+> tupledS (ppDeclarationRef <$> exps)
  <+> "where"

ppModule :: P.Module -> Doc
ppModule (P.Module _ moduleComments mn decls exports) = vsep
  [ vsep (ppComment <$> moduleComments)
  , empty
  , ppModuleHeader mn exports
  , empty
  , vsep (ppDeclaration <$> decls)
  ]

printor :: IO ()
printor = putDoc =<< ((<> line) . ppModule) <$> moduleFromFile
