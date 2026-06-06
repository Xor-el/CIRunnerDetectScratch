program Make;
{$MODE DELPHI}
{$SCOPEDENUMS ON}

uses
  SysUtils, Classes, Contnrs, StrUtils, Process, RegExpr, Zipper, fphttpclient,
  openssl, opensslsockets;

type
  TMakeRunner = class;

  // ---------------------------------------------------------------------------
  // Build backend
  // ---------------------------------------------------------------------------

  TBuildBackend = (
    Auto,
    Lazbuild,
    Fpc
  );

  // ---------------------------------------------------------------------------
  // Dependency configuration
  // ---------------------------------------------------------------------------

  TDependencyKind = (OPM, GitHub);

  TDependency = record
    Kind: TDependencyKind;
    Name: string;  // OPM: package name | GitHub: 'owner/repo'
    Ref: string;   // GitHub: branch, tag or commit (ignored for OPM)
  end;

  // ---------------------------------------------------------------------------
  // Lazarus project / package XML
  // ---------------------------------------------------------------------------

  TLazCompilerOptions = record
    CompilerMode: string;
    OptLevel: string;
    UseDwarfSets: Boolean;
    CustomConfigFile: string;
    IncludePaths: string;
    UnitPaths: string;
    UnitOutputDirTemplate: string;
  end;

  TLazXml = class
  public
    class function ReadFile(const AFileName: string): string;
    class function ExtractBlock(const AContent, AOpenTag: string): string;
    class function ExtractAttr(const AContent, ATag: string): string;
    class function ParseCompilerOptions(const AContent: string): TLazCompilerOptions;
    class function ResolveUnitOutputDir(const AOptions: TLazCompilerOptions;
      const AProjDir, ATargetCpu, ATargetOs: string): string;
    class procedure AppendCompilerOptionsToArgv(const AOptions: TLazCompilerOptions;
      const AProjDir, AUnitOutDir, APkgOutDir, ATargetCpu, ATargetOs: string;
      AArgs: TStrings);
    class function ResolvePath(const AValue, AProjDir, AUnitOutDir, APkgOutDir,
      ATargetCpu, ATargetOs: string): string;
  private
    class function IsAbsolutePath(const S: string): Boolean;
    class function ExpandMacros(const S, AProjDir, AUnitOutDir, APkgOutDir,
      ATargetCpu, ATargetOs: string): string;
    class procedure AppendSearchPathArgs(const APaths, AProjDir, AUnitOutDir,
      APkgOutDir, ATargetCpu, ATargetOs, APrefix: string; AArgs: TStrings);
  end;

  TProjectFiles = class
  public
    class function FindAll(const ASearchDir, AMask: string): TStringList;
  private
    class function MatchesMask(const AFileName, AMask: string): Boolean;
    class procedure FindRecursive(const ADir, AMask: string; AList: TStrings);
  end;

  TLpiProject = class
  private
    FLpiPath: string;
    FProjDir: string;
    FMainLpr: string;
    FUnitOutDir: string;
    FTargetBinary: string;
    FOptions: TLazCompilerOptions;
    FRequiredPackageNames: TStringList;
  public
    constructor CreateFromFile(const ALpiPath, ATargetCpu, ATargetOs: string);
    destructor Destroy; override;
    function IsValid: Boolean;
    function BuildFpcArgv(const AExtraUnitPaths: TStrings;
      ATargetCpu, ATargetOs: string): TStringList;
    property RequiredPackageNames: TStringList read FRequiredPackageNames;
    property TargetBinary: string read FTargetBinary;
  end;

  TLpkPackage = class
  private
    FLpkPath: string;
    FPkgDir: string;
    FPackageName: string;
    FStubPas: string;
    FUnitOutDir: string;
    FOptions: TLazCompilerOptions;
    FRequiredNames: TStringList;
    FHasLclDependency: Boolean;
  public
    constructor CreateFromFile(const ALpkPath, ATargetCpu, ATargetOs: string);
    destructor Destroy; override;
    function IsValid: Boolean;
    property PackageName: string read FPackageName;
    property UnitOutDir: string read FUnitOutDir;
    property PkgDir: string read FPkgDir;
    property Options: TLazCompilerOptions read FOptions;
    property RequiredNames: TStringList read FRequiredNames;
    property StubPas: string read FStubPas;
    property HasLclDependency: Boolean read FHasLclDependency;
  end;

  TPackageGraph = class
  private
    FRunner: TMakeRunner;
    FItems: TObjectList;
    FNameToIndex: TStringList;
    function GetPackage(Index: Integer): TLpkPackage;
    function FindIndexByName(const AName: string): Integer;
    function IsBuiltinPackage(const AName: string): Boolean;
    procedure CollectBuildOrder(const AIndex: Integer; AOrder: TList);
    procedure CollectUnitPaths(const AIndex: Integer; AVisited: TList;
      APaths: TStrings);
  public
    constructor Create(ARunner: TMakeRunner);
    destructor Destroy; override;
    procedure DiscoverUnder(const ARoot: string);
    procedure RegisterLpk(const ALpkPath: string);
    function BuildAll: Boolean;
    function UnitPathFor(const APackageName: string): string;
    function UnitPathsForRequired(const ANames: TStrings): TStringList;
    function PackageCount: Integer;
    class function ExcludePattern: string;
  end;

  // ---------------------------------------------------------------------------
  // Main orchestrator
  // ---------------------------------------------------------------------------

  TMakeRunner = class
  private
    FBackend: TBuildBackend;
    FBackendResolved: Boolean;
    FTargetCpu: string;
    FTargetOs: string;
    FErrorCount: Integer;
    FGraph: TPackageGraph;
    function ParseBackendEnv: TBuildBackend;
    function ResolveAutoBackend: TBuildBackend;
    procedure InitEnvironment;
    procedure UpdateSubmodules;
    procedure InstallDependencies;
    procedure BuildAllProjects;
    function BuildProject(const ALpiPath: string): string;
    function BuildProjectWithLazbuild(const APath: string): string;
    function BuildProjectWithFpc(const APath: string): string;
    function ExtractBinaryFromBuildLog(const AOutput, AFallback: string): string;
    function IsGUIProject(const ALpiPath: string): Boolean;
    function IsTestProject(const ALpiPath: string): Boolean;
    procedure RunTestProject(const APath: string);
    procedure RunSampleProject(const APath: string);
    procedure InitSslForDownloads;
    procedure DownloadAndExtract(const AUrl, ADestDir: string);
    function GetDepsBaseDir(const ASubDir: string): string;
    function InstallOPMPackage(const APackageName: string): string;
    function InstallGitHubPackage(const AOwnerRepo, ARef: string): string;
    function ResolveDependency(const ADep: TDependency): string;
    procedure RegisterPackageLazbuild(const APath: string);
    procedure RegisterAllPackagesLazbuild(const ASearchDir: string);
    function UsesLazbuild: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    function Execute: Integer;
    procedure Log(const AColor, AMessage: string);
    procedure LogInline(const AColor, AMessage: string);
    procedure ReportBuildErrors(const ABuildOutput: string);
    procedure ReportSummary;
    procedure IncError;
    property TargetCpu: string read FTargetCpu;
    property TargetOs: string read FTargetOs;
  end;

// ---------------------------------------------------------------------------
// Configuration constants
// ---------------------------------------------------------------------------

const
  Target = 'CIRunnerDetect.Demo';

  CSI_Reset  = #27'[0m';
  CSI_Red    = #27'[31m';
  CSI_Green  = #27'[32m';
  CSI_Yellow = #27'[33m';
  CSI_Cyan   = #27'[36m';

  OPMBaseUrl = 'https://packages.lazarus-ide.org/';
  GitHubArchiveBaseUrl = 'https://github.com/';

  Dependencies: array[0..0] of TDependency = (
    // Examples:
       (Kind: TDependencyKind.GitHub; Name: 'Xor-el/SimpleBaseLib4Pascal';  Ref: 'master')
    // (Kind: TDependencyKind.OPM;    Name: 'HashLib';               Ref: ''),
    // (Kind: TDependencyKind.GitHub; Name: 'Xor-el/SimpleBaseLib4Pascal';  Ref: 'master'),
  );

// ---------------------------------------------------------------------------
// Dependency helpers
// ---------------------------------------------------------------------------

function OPM(const AName: string): TDependency;
begin
  Result.Kind := TDependencyKind.OPM;
  Result.Name := AName;
  Result.Ref := '';
end;

function GitHub(const AOwnerRepo, ARef: string): TDependency;
begin
  Result.Kind := TDependencyKind.GitHub;
  Result.Name := AOwnerRepo;
  Result.Ref := ARef;
end;

// ---------------------------------------------------------------------------
// TLazXml
// ---------------------------------------------------------------------------

{ TLazXml }

class function TLazXml.IsAbsolutePath(const S: string): Boolean;
begin
  {$IFDEF MSWINDOWS}
  Result := (Length(S) >= 2) and (
    ((UpCase(S[1]) >= 'A') and (UpCase(S[1]) <= 'Z') and (S[2] = ':')) or
    (S[1] = '\'));
  {$ELSE}
  Result := (Length(S) > 0) and (S[1] = '/');
  {$ENDIF}
end;

class function TLazXml.ReadFile(const AFileName: string): string;
var
  Stream: TFileStream;
  Size: Int64;
begin
  Result := '';
  Stream := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyNone);
  try
    Size := Stream.Size;
    if Size <= 0 then
      Exit;
    SetLength(Result, Size);
    Stream.Position := 0;
    Stream.ReadBuffer(Pointer(Result)^, Size);
  finally
    Stream.Free;
  end;
end;

class function TLazXml.ExtractBlock(const AContent, AOpenTag: string): string;
var
  P, Q: Integer;
  CloseTag: string;
begin
  Result := '';
  P := Pos('<' + AOpenTag, AContent);
  if P = 0 then
    Exit;
  CloseTag := '</' + AOpenTag + '>';
  Q := PosEx(CloseTag, AContent, P);
  if Q = 0 then
    Result := Copy(AContent, P, MaxInt)
  else
    Result := Copy(AContent, P, Q - P + Length(CloseTag));
end;

class function TLazXml.ExtractAttr(const AContent, ATag: string): string;
var
  Needle: string;
  P, Q: Integer;
begin
  Result := '';
  Needle := '<' + ATag + ' Value="';
  P := Pos(Needle, AContent);
  if P = 0 then
    Exit;
  Inc(P, Length(Needle));
  Q := PosEx('"', AContent, P);
  if Q = 0 then
    Exit;
  Result := Copy(AContent, P, Q - P);
end;

class function TLazXml.ExpandMacros(const S, AProjDir, AUnitOutDir, APkgOutDir,
  ATargetCpu, ATargetOs: string): string;
begin
  Result := S;
  Result := StringReplace(Result, '$(ProjOutDir)', AUnitOutDir, [rfReplaceAll]);
  Result := StringReplace(Result, '$(PkgOutDir)', APkgOutDir, [rfReplaceAll]);
  Result := StringReplace(Result, '$(TargetCPU)', ATargetCpu, [rfReplaceAll]);
  Result := StringReplace(Result, '$(TargetOS)', ATargetOs, [rfReplaceAll]);
  Result := StringReplace(Result, '\', PathDelim, [rfReplaceAll]);
  if Result = '' then
    Exit;
  if not IsAbsolutePath(Result) then
    Result := ExpandFileName(IncludeTrailingPathDelimiter(AProjDir) + Result);
end;

class function TLazXml.ResolvePath(const AValue, AProjDir, AUnitOutDir,
  APkgOutDir, ATargetCpu, ATargetOs: string): string;
begin
  Result := ExpandMacros(Trim(AValue), AProjDir, AUnitOutDir, APkgOutDir,
    ATargetCpu, ATargetOs);
end;

class procedure TLazXml.AppendSearchPathArgs(const APaths, AProjDir,
  AUnitOutDir, APkgOutDir, ATargetCpu, ATargetOs, APrefix: string;
  AArgs: TStrings);
var
  Parts: TStringArray;
  I: Integer;
  PathItem: string;
begin
  Parts := SplitString(APaths, ';');
  for I := 0 to High(Parts) do
  begin
    PathItem := Trim(Parts[I]);
    if PathItem = '' then
      Continue;
    AArgs.Add(APrefix + ResolvePath(PathItem, AProjDir, AUnitOutDir, APkgOutDir,
      ATargetCpu, ATargetOs));
  end;
end;

class function TLazXml.ParseCompilerOptions(const AContent: string): TLazCompilerOptions;
var
  Block: string;
  P: Integer;
begin
  Result.CompilerMode := 'delphi';
  Result.OptLevel := '2';
  Result.UseDwarfSets := Pos('dsDwarf3', AContent) > 0;
  Result.CustomConfigFile := '';
  Result.IncludePaths := '';
  Result.UnitPaths := '';
  Result.UnitOutputDirTemplate := 'lib\$(TargetCPU)-$(TargetOS)';

  P := Pos('<CompilerOptions>', AContent);
  if P = 0 then
    Exit;
  Block := Copy(AContent, P, MaxInt);

  if ExtractAttr(Block, 'OptimizationLevel') <> '' then
    Result.OptLevel := ExtractAttr(Block, 'OptimizationLevel');
  Result.IncludePaths := ExtractAttr(Block, 'IncludeFiles');
  Result.UnitPaths := ExtractAttr(Block, 'OtherUnitFiles');
  if ExtractAttr(Block, 'UnitOutputDirectory') <> '' then
    Result.UnitOutputDirTemplate := ExtractAttr(Block, 'UnitOutputDirectory');

  if Pos('<CustomConfigFile Value="True"', Block) > 0 then
    Result.CustomConfigFile := ExtractAttr(Block, 'ConfigFilePath');
end;

class function TLazXml.ResolveUnitOutputDir(const AOptions: TLazCompilerOptions;
  const AProjDir, ATargetCpu, ATargetOs: string): string;
begin
  Result := ResolvePath(AOptions.UnitOutputDirTemplate, AProjDir, '', '',
    ATargetCpu, ATargetOs);
  ForceDirectories(Result);
end;

class procedure TLazXml.AppendCompilerOptionsToArgv(const AOptions: TLazCompilerOptions;
  const AProjDir, AUnitOutDir, APkgOutDir, ATargetCpu, ATargetOs: string;
  AArgs: TStrings);
var
  ConfigPath: string;
begin
  if AOptions.CompilerMode <> '' then
    AArgs.Add('-M' + AOptions.CompilerMode)
  else
    AArgs.Add('-Mdelphi');
  AArgs.Add('-O' + AOptions.OptLevel);
  if AOptions.UseDwarfSets then
    AArgs.Add('-godwarfsets');
  AppendSearchPathArgs(AOptions.IncludePaths, AProjDir, AUnitOutDir, APkgOutDir,
    ATargetCpu, ATargetOs, '-Fi', AArgs);
  AppendSearchPathArgs(AOptions.UnitPaths, AProjDir, AUnitOutDir, APkgOutDir,
    ATargetCpu, ATargetOs, '-Fu', AArgs);
  if AOptions.CustomConfigFile <> '' then
  begin
    ConfigPath := ResolvePath(AOptions.CustomConfigFile, AProjDir, AUnitOutDir,
      APkgOutDir, ATargetCpu, ATargetOs);
    if FileExists(ConfigPath) then
      AArgs.Add('@' + ConfigPath);
  end;
end;

// ---------------------------------------------------------------------------
// TProjectFiles
// ---------------------------------------------------------------------------

{ TProjectFiles }

class function TProjectFiles.MatchesMask(const AFileName, AMask: string): Boolean;
var
  LExt: string;
begin
  LExt := LowerCase(ExtractFileExt(AFileName));
  if AMask = '*.lpk' then
    Exit(LExt = '.lpk');
  if AMask = '*.lpi' then
    Exit(LExt = '.lpi');
  Result := False;
end;

class procedure TProjectFiles.FindRecursive(const ADir, AMask: string;
  AList: TStrings);
var
  Search: TSearchRec;
  DirPath, EntryPath: string;
begin
  DirPath := IncludeTrailingPathDelimiter(ExpandFileName(ADir));
  if FindFirst(DirPath + '*', faAnyFile, Search) = 0 then
  try
    repeat
      if (Search.Name = '.') or (Search.Name = '..') then
        Continue;
      EntryPath := DirPath + Search.Name;
      if (Search.Attr and faDirectory) <> 0 then
        FindRecursive(EntryPath, AMask, AList)
      else if MatchesMask(Search.Name, AMask) then
        AList.Add(EntryPath);
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

class function TProjectFiles.FindAll(const ASearchDir, AMask: string): TStringList;
begin
  Result := TStringList.Create;
  FindRecursive(ASearchDir, AMask, Result);
end;

// ---------------------------------------------------------------------------
// TLpiProject
// ---------------------------------------------------------------------------

{ TLpiProject }

constructor TLpiProject.CreateFromFile(const ALpiPath, ATargetCpu,
  ATargetOs: string);
var
  Content, Block, Name: string;
  P: Integer;
  Filter: TRegExpr;
begin
  inherited Create;
  FRequiredPackageNames := TStringList.Create;
  FLpiPath := ALpiPath;
  FProjDir := ExtractFilePath(ALpiPath);

  if not FileExists(ALpiPath) then
    Exit;

  Content := TLazXml.ReadFile(ALpiPath);
  FOptions := TLazXml.ParseCompilerOptions(Content);
  FUnitOutDir := TLazXml.ResolveUnitOutputDir(FOptions, FProjDir, ATargetCpu, ATargetOs);

  P := Pos('<Unit0>', Content);
  if P > 0 then
    Block := Copy(Content, P, MaxInt)
  else
    Block := Content;
  Name := TLazXml.ExtractAttr(Block, 'Filename');
  if Name <> '' then
    FMainLpr := TLazXml.ResolvePath(Name, FProjDir, '', '', ATargetCpu, ATargetOs);

  P := Pos('<Target>', Content);
  if P > 0 then
  begin
    Block := Copy(Content, P, 500);
    Name := TLazXml.ExtractAttr(Block, 'Filename');
    if Name <> '' then
      FTargetBinary := TLazXml.ResolvePath(Name, FProjDir, FUnitOutDir, '',
        ATargetCpu, ATargetOs);
  end;
  if FTargetBinary = '' then
    FTargetBinary := ChangeFileExt(FMainLpr, '');

  Block := TLazXml.ExtractBlock(Content, 'RequiredPkgs');
  if Block <> '' then
  begin
    Filter := TRegExpr.Create('<PackageName\s+Value="([^"]+)"\s*/>');
    try
      if Filter.Exec(Block) then
      repeat
        FRequiredPackageNames.Add(Filter.Match[1]);
      until not Filter.ExecNext;
    finally
      Filter.Free;
    end;
  end;
end;

destructor TLpiProject.Destroy;
begin
  FRequiredPackageNames.Free;
  inherited Destroy;
end;

function TLpiProject.IsValid: Boolean;
begin
  Result := (FLpiPath <> '') and FileExists(FLpiPath) and (FMainLpr <> '') and
    FileExists(FMainLpr);
end;

function TLpiProject.BuildFpcArgv(const AExtraUnitPaths: TStrings;
  ATargetCpu, ATargetOs: string): TStringList;
var
  I: Integer;
begin
  Result := TStringList.Create;
  TLazXml.AppendCompilerOptionsToArgv(FOptions, FProjDir, FUnitOutDir, FUnitOutDir,
    ATargetCpu, ATargetOs, Result);
  if Assigned(AExtraUnitPaths) then
    for I := 0 to AExtraUnitPaths.Count - 1 do
      Result.Add('-Fu' + AExtraUnitPaths[I]);
  Result.Add('-FU' + FUnitOutDir);
  Result.Add('-FE' + ExtractFilePath(FTargetBinary));
  Result.Add('-o' + FTargetBinary);
  Result.Add(FMainLpr);
end;

// ---------------------------------------------------------------------------
// TLpkPackage
// ---------------------------------------------------------------------------

{ TLpkPackage }

constructor TLpkPackage.CreateFromFile(const ALpkPath, ATargetCpu,
  ATargetOs: string);
var
  Content: string;
  P: Integer;
  Filter: TRegExpr;
  Block: string;
  Units, UnitName: string;
  SL: TStringList;
begin
  inherited Create;
  FRequiredNames := TStringList.Create;
  FLpkPath := ALpkPath;
  FPkgDir := ExtractFilePath(ALpkPath);

  if not FileExists(ALpkPath) then
    Exit;

  Content := TLazXml.ReadFile(ALpkPath);
  P := Pos('<Package>', Content);
  if P > 0 then
    FPackageName := TLazXml.ExtractAttr(Copy(Content, P, 2000), 'Name')
  else
    FPackageName := TLazXml.ExtractAttr(Content, 'Name');
  FOptions := TLazXml.ParseCompilerOptions(Content);
  FUnitOutDir := TLazXml.ResolveUnitOutputDir(FOptions, FPkgDir, ATargetCpu, ATargetOs);

  Block := TLazXml.ExtractBlock(Content, 'RequiredPkgs');
  if Block <> '' then
  begin
    Filter := TRegExpr.Create('<PackageName\s+Value="([^"]+)"\s*/>');
    try
      if Filter.Exec(Block) then
      repeat
        if SameText(Filter.Match[1], 'LCL') then
          FHasLclDependency := True;
        FRequiredNames.Add(Filter.Match[1]);
      until not Filter.ExecNext;
    finally
      Filter.Free;
    end;
  end;

  FStubPas := IncludeTrailingPathDelimiter(FPkgDir) + FPackageName + '.pas';
  if not FileExists(FStubPas) then
  begin
    Units := '';
    Filter := TRegExpr.Create('<UnitName\s+Value="([^"]+)"\s*/>');
    try
      if Filter.Exec(Content) then
      repeat
        UnitName := Filter.Match[1];
        if Units <> '' then
          Units := Units + ', ';
        Units := Units + UnitName;
      until not Filter.ExecNext;
    finally
      Filter.Free;
    end;

    SL := TStringList.Create;
    try
      SL.Add('{ Auto-generated by Make for package compile }');
      SL.Add('');
      SL.Add('unit ' + FPackageName + ';');
      SL.Add('');
      SL.Add('{$warn 5023 off : no warning about unused units}');
      SL.Add('interface');
      SL.Add('');
      SL.Add('uses');
      SL.Add('  ' + Units + ';');
      SL.Add('');
      SL.Add('implementation');
      SL.Add('');
      SL.Add('end.');
      SL.SaveToFile(FStubPas);
    finally
      SL.Free;
    end;
  end;
end;

destructor TLpkPackage.Destroy;
begin
  FRequiredNames.Free;
  inherited Destroy;
end;

function TLpkPackage.IsValid: Boolean;
begin
  Result := (FLpkPath <> '') and FileExists(FLpkPath) and (FPackageName <> '') and
    (FStubPas <> '') and FileExists(FStubPas);
end;

// ---------------------------------------------------------------------------
// TPackageGraph
// ---------------------------------------------------------------------------

{ TPackageGraph }

class function TPackageGraph.ExcludePattern: string;
begin
  {$IF DEFINED(MSWINDOWS)}
  Result := '(cocoa|x11|_template)';
  {$ELSEIF DEFINED(DARWIN)}
  Result := '(gdi|x11|_template)';
  {$ELSE}
  Result := '(cocoa|gdi|_template)';
  {$IFEND}
end;

constructor TPackageGraph.Create(ARunner: TMakeRunner);
begin
  inherited Create;
  FRunner := ARunner;
  FItems := TObjectList.Create(True);
  FNameToIndex := TStringList.Create;
  FNameToIndex.Sorted := True;
  FNameToIndex.Duplicates := dupError;
end;

destructor TPackageGraph.Destroy;
begin
  FNameToIndex.Free;
  FItems.Free;
  inherited Destroy;
end;

function TPackageGraph.GetPackage(Index: Integer): TLpkPackage;
begin
  Result := TLpkPackage(FItems[Index]);
end;

function TPackageGraph.PackageCount: Integer;
begin
  Result := FItems.Count;
end;

function TPackageGraph.IsBuiltinPackage(const AName: string): Boolean;
begin
  Result := SameText(AName, 'FCL') or SameText(AName, 'RTL') or
    SameText(AName, 'FCLBase');
end;

function TPackageGraph.FindIndexByName(const AName: string): Integer;
var
  Idx: Integer;
begin
  Result := -1;
  Idx := FNameToIndex.IndexOf(AName);
  if Idx >= 0 then
    Result := Integer(FNameToIndex.Objects[Idx]);
end;

procedure TPackageGraph.RegisterLpk(const ALpkPath: string);
var
  Filter: TRegExpr;
  Pkg: TLpkPackage;
begin
  Filter := TRegExpr.Create(ExcludePattern);
  try
    if Filter.Exec(ALpkPath) then
      Exit;
  finally
    Filter.Free;
  end;

  Pkg := TLpkPackage.CreateFromFile(ALpkPath, FRunner.TargetCpu, FRunner.TargetOs);
  if not Pkg.IsValid then
  begin
    FRunner.Log(CSI_Red, 'failed to load package: ' + ALpkPath);
    FRunner.IncError;
    Pkg.Free;
    Exit;
  end;

  if Pkg.HasLclDependency then
  begin
    FRunner.Log(CSI_Yellow, 'skip LCL-dependent package ' + ALpkPath);
    Pkg.Free;
    Exit;
  end;

  if FindIndexByName(Pkg.PackageName) >= 0 then
  begin
    Pkg.Free;
    Exit;
  end;

  FNameToIndex.AddObject(Pkg.PackageName, TObject(FItems.Count));
  FItems.Add(Pkg);
end;

procedure TPackageGraph.DiscoverUnder(const ARoot: string);
var
  List: TStringList;
  Each: string;
begin
  if not DirectoryExists(ARoot) then
    Exit;
  List := TProjectFiles.FindAll(ARoot, '*.lpk');
  try
    for Each in List do
      RegisterLpk(Each);
  finally
    List.Free;
  end;
end;

procedure TPackageGraph.CollectBuildOrder(const AIndex: Integer; AOrder: TList);
var
  Pkg: TLpkPackage;
  I, DepIdx: Integer;
  DepName: string;
begin
  if (AIndex < 0) or (AIndex >= FItems.Count) then
    Exit;
  if AOrder.IndexOf(Pointer(AIndex)) >= 0 then
    Exit;
  Pkg := GetPackage(AIndex);
  for I := 0 to Pkg.RequiredNames.Count - 1 do
  begin
    DepName := Pkg.RequiredNames[I];
    if IsBuiltinPackage(DepName) then
      Continue;
    DepIdx := FindIndexByName(DepName);
    if DepIdx < 0 then
    begin
      FRunner.Log(CSI_Red, Format('package "%s" requires unknown "%s"',
        [Pkg.PackageName, DepName]));
      FRunner.IncError;
      Continue;
    end;
    CollectBuildOrder(DepIdx, AOrder);
  end;
  AOrder.Add(Pointer(AIndex));
end;

procedure TPackageGraph.CollectUnitPaths(const AIndex: Integer; AVisited: TList;
  APaths: TStrings);
var
  Pkg: TLpkPackage;
  I, DepIdx: Integer;
  DepName, Path: string;
begin
  if (AIndex < 0) or (AIndex >= FItems.Count) then
    Exit;
  if AVisited.IndexOf(Pointer(AIndex)) >= 0 then
    Exit;
  AVisited.Add(Pointer(AIndex));

  Pkg := GetPackage(AIndex);
  for I := 0 to Pkg.RequiredNames.Count - 1 do
  begin
    DepName := Pkg.RequiredNames[I];
    if IsBuiltinPackage(DepName) then
      Continue;
    DepIdx := FindIndexByName(DepName);
    if DepIdx < 0 then
    begin
      FRunner.Log(CSI_Red, Format('package "%s" requires unknown "%s"',
        [Pkg.PackageName, DepName]));
      FRunner.IncError;
      Continue;
    end;
    CollectUnitPaths(DepIdx, AVisited, APaths);
  end;

  Path := Pkg.UnitOutDir;
  if (Path <> '') and (APaths.IndexOf(Path) < 0) then
    APaths.Add(Path);
end;

function TPackageGraph.BuildAll: Boolean;
var
  Order: TList;
  I, Idx, J: Integer;
  Pkg: TLpkPackage;
  Args: TStringList;
  BuildOutput: AnsiString;
  ArgArray: array of string;
  DepPath: string;
begin
  Result := True;
  if FItems.Count = 0 then
    Exit;

  Order := TList.Create;
  try
    for I := 0 to FItems.Count - 1 do
      CollectBuildOrder(I, Order);

    for I := 0 to Order.Count - 1 do
    begin
      Idx := Integer(Order[I]);
      Pkg := GetPackage(Idx);

      FRunner.LogInline(CSI_Yellow, 'build package ' + Pkg.PackageName);
      ForceDirectories(Pkg.UnitOutDir);

      Args := TStringList.Create;
      try
        TLazXml.AppendCompilerOptionsToArgv(Pkg.Options, Pkg.PkgDir, Pkg.UnitOutDir,
          Pkg.UnitOutDir, FRunner.TargetCpu, FRunner.TargetOs, Args);
        for J := 0 to Pkg.RequiredNames.Count - 1 do
        begin
          if IsBuiltinPackage(Pkg.RequiredNames[J]) then
            Continue;
          DepPath := UnitPathFor(Pkg.RequiredNames[J]);
          if DepPath <> '' then
            Args.Add('-Fu' + DepPath);
        end;
        Args.Add('-FU' + Pkg.UnitOutDir);
        Args.Add('-FE' + Pkg.UnitOutDir);
        Args.Add('-B');
        Args.Add(Pkg.StubPas);

        SetLength(ArgArray, Args.Count);
        for J := 0 to Args.Count - 1 do
          ArgArray[J] := Args[J];
        if RunCommand('fpc', ArgArray, BuildOutput) then
        begin
          WriteLn(stderr, string(BuildOutput));
          FRunner.Log(CSI_Green, ' -> ' + Pkg.UnitOutDir);
        end
        else
        begin
          WriteLn(stderr, string(BuildOutput));
          FRunner.IncError;
          FRunner.ReportBuildErrors(string(BuildOutput));
          Result := False;
        end;
      finally
        Args.Free;
      end;
    end;
  finally
    Order.Free;
  end;
end;

function TPackageGraph.UnitPathFor(const APackageName: string): string;
var
  Idx: Integer;
begin
  Result := '';
  Idx := FindIndexByName(APackageName);
  if (Idx < 0) or (Idx >= FItems.Count) then
    Exit;
  Result := GetPackage(Idx).UnitOutDir;
end;

function TPackageGraph.UnitPathsForRequired(const ANames: TStrings): TStringList;
var
  I, Idx: Integer;
  Visited: TList;
begin
  Result := TStringList.Create;
  if not Assigned(ANames) then
    Exit;

  Visited := TList.Create;
  try
    for I := 0 to ANames.Count - 1 do
    begin
      if IsBuiltinPackage(ANames[I]) then
        Continue;
      Idx := FindIndexByName(ANames[I]);
      if Idx < 0 then
      begin
        FRunner.Log(CSI_Red, Format('project requires unknown package "%s"',
          [ANames[I]]));
        FRunner.IncError;
        Continue;
      end;
      CollectUnitPaths(Idx, Visited, Result);
    end;
  finally
    Visited.Free;
  end;
end;

// ---------------------------------------------------------------------------
// TMakeRunner
// ---------------------------------------------------------------------------

{ TMakeRunner }

constructor TMakeRunner.Create;
begin
  inherited Create;
  FBackend := TBuildBackend.Auto;
  FBackendResolved := False;
  FErrorCount := 0;
  FGraph := TPackageGraph.Create(Self);
end;

destructor TMakeRunner.Destroy;
begin
  FGraph.Free;
  inherited Destroy;
end;

procedure TMakeRunner.Log(const AColor, AMessage: string);
begin
  WriteLn(stderr, AColor, AMessage, CSI_Reset);
end;

procedure TMakeRunner.LogInline(const AColor, AMessage: string);
begin
  Write(stderr, AColor, AMessage, CSI_Reset);
end;

procedure TMakeRunner.IncError;
begin
  Inc(FErrorCount);
end;

procedure TMakeRunner.ReportBuildErrors(const ABuildOutput: string);
var
  Line: string;
  ErrorFilter: TRegExpr;
begin
  ErrorFilter := TRegExpr.Create('(Fatal|Error):');
  try
    for Line in SplitString(ABuildOutput, LineEnding) do
      if ErrorFilter.Exec(Line) then
        Log(CSI_Red, Line);
  finally
    ErrorFilter.Free;
  end;
end;

procedure TMakeRunner.ReportSummary;
begin
  WriteLn(stderr);
  if FErrorCount > 0 then
    Log(CSI_Red, 'Errors: ' + IntToStr(FErrorCount))
  else
    Log(CSI_Green, 'Errors: 0');
end;

function TMakeRunner.ParseBackendEnv: TBuildBackend;
var
  Env: string;
begin
  Env := LowerCase(Trim(GetEnvironmentVariable('MAKE_BUILD_BACKEND')));
  if (Env = '') or (Env = 'auto') then
    Exit(TBuildBackend.Auto);
  if Env = 'lazbuild' then
    Exit(TBuildBackend.Lazbuild);
  if Env = 'fpc' then
    Exit(TBuildBackend.Fpc);
  raise Exception.CreateFmt('unknown MAKE_BUILD_BACKEND: "%s"', [Env]);
end;

function TMakeRunner.ResolveAutoBackend: TBuildBackend;
var
  Output: AnsiString;
begin
  if RunCommand('lazbuild', ['--version'], Output) then
    Exit(TBuildBackend.Lazbuild);
  Result := TBuildBackend.Fpc;
end;

function TMakeRunner.UsesLazbuild: Boolean;
begin
  if not FBackendResolved then
    InitEnvironment;
  Result := FBackend = TBuildBackend.Lazbuild;
end;

procedure TMakeRunner.InitEnvironment;
var
  Requested: TBuildBackend;
  Output: AnsiString;
begin
  if FBackendResolved then
    Exit;

  if RunCommand('fpc', ['-iT'], Output) then
    FTargetCpu := Trim(string(Output));
  if RunCommand('fpc', ['-iSO'], Output) then
    FTargetOs := Trim(string(Output));

  Requested := ParseBackendEnv;
  case Requested of
    TBuildBackend.Lazbuild:
      begin
        if not RunCommand('lazbuild', ['--version'], Output) then
          raise Exception.Create('MAKE_BUILD_BACKEND=lazbuild but lazbuild not found');
        FBackend := TBuildBackend.Lazbuild;
      end;
    TBuildBackend.Fpc:
      FBackend := TBuildBackend.Fpc;
    TBuildBackend.Auto:
      FBackend := ResolveAutoBackend;
  end;

  FBackendResolved := True;
  case FBackend of
    TBuildBackend.Lazbuild:
      Log(CSI_Yellow, 'build backend: lazbuild');
    TBuildBackend.Fpc:
      Log(CSI_Yellow, 'build backend: fpc');
    TBuildBackend.Auto:
      ;
  end;
end;

procedure TMakeRunner.UpdateSubmodules;
var
  CommandOutput: AnsiString;
begin
  if not FileExists('.gitmodules') then
    Exit;
  if RunCommand('git', ['submodule', 'update', '--init', '--recursive',
    '--force', '--remote'], CommandOutput) then
    Log(CSI_Yellow, Trim(string(CommandOutput)));
end;

// FPC 3.2.2 hardcodes OpenSSL 1.1 DLL names on Windows, but
// modern CI runners ship OpenSSL 3.x. Override so FPC can find
// the libraries. This hack can be removed once we move to
// FPC 3.2.4+ which natively includes OpenSSL 3.x DLL names.
procedure TMakeRunner.InitSslForDownloads;
begin
  {$IFDEF MSWINDOWS}
    {$IFDEF WIN64}
  DLLSSLName := 'libssl-3-x64.dll';
  DLLUtilName := 'libcrypto-3-x64.dll';
    {$ELSE}
  DLLSSLName := 'libssl-3.dll';
  DLLUtilName := 'libcrypto-3.dll';
    {$ENDIF}
  {$ENDIF}
  InitSSLInterface;
end;

procedure TMakeRunner.DownloadAndExtract(const AUrl, ADestDir: string);
var
  TempFile: string;
  Stream: TFileStream;
  Client: TFPHttpClient;
  Unzipper: TUnZipper;
begin
  TempFile := GetTempFileName;
  Stream := TFileStream.Create(TempFile, fmCreate or fmOpenWrite);
  try
    Client := TFPHttpClient.Create(nil);
    try
      Client.AddHeader('User-Agent', 'Mozilla/5.0 (compatible; fpweb)');
      Client.AllowRedirect := True;
      Client.Get(AUrl, Stream);
      Log(CSI_Cyan, 'downloaded ' + AUrl);
    finally
      Client.Free;
    end;
  finally
    Stream.Free;
  end;

  CreateDir(ADestDir);
  Unzipper := TUnZipper.Create;
  try
    Unzipper.FileName := TempFile;
    Unzipper.OutputPath := ADestDir;
    Unzipper.Examine;
    Unzipper.UnZipAllFiles;
    Log(CSI_Cyan, 'extracted to ' + ADestDir);
  finally
    Unzipper.Free;
    DeleteFile(TempFile);
  end;
end;

function TMakeRunner.GetDepsBaseDir(const ASubDir: string): string;
var
  BaseDir: string;
begin
  {$IFDEF MSWINDOWS}
  BaseDir := GetEnvironmentVariable('APPDATA');
  {$ELSE}
  BaseDir := GetEnvironmentVariable('HOME');
  {$ENDIF}
  Result := IncludeTrailingPathDelimiter(ConcatPaths([BaseDir, '.lazarus', ASubDir]));
end;

function TMakeRunner.InstallOPMPackage(const APackageName: string): string;
begin
  Result := GetDepsBaseDir(ConcatPaths(['onlinepackagemanager', 'packages'])) +
    APackageName;
  if DirectoryExists(Result) then
    Exit;
  DownloadAndExtract(OPMBaseUrl + APackageName + '.zip', Result);
end;

function TMakeRunner.InstallGitHubPackage(const AOwnerRepo, ARef: string): string;
var
  SafeName, EffectiveRef: string;
begin
  SafeName := StringReplace(AOwnerRepo, '/', '--', [rfReplaceAll]);
  EffectiveRef := ARef;
  if EffectiveRef = '' then
    EffectiveRef := 'main';

  Result := GetDepsBaseDir('github-packages') + SafeName;
  if DirectoryExists(Result) then
    Exit;

  DownloadAndExtract(
    GitHubArchiveBaseUrl + AOwnerRepo + '/archive/' + EffectiveRef + '.zip',
    Result);
end;

function TMakeRunner.ResolveDependency(const ADep: TDependency): string;
begin
  case ADep.Kind of
    TDependencyKind.OPM:
      Result := InstallOPMPackage(ADep.Name);
    TDependencyKind.GitHub:
      Result := InstallGitHubPackage(ADep.Name, ADep.Ref);
  else
    raise Exception.CreateFmt('Unknown dependency kind for "%s"', [ADep.Name]);
  end;
end;

procedure TMakeRunner.RegisterPackageLazbuild(const APath: string);
var
  Filter: TRegExpr;
  CommandOutput: AnsiString;
begin
  Filter := TRegExpr.Create(TPackageGraph.ExcludePattern);
  try
    if Filter.Exec(APath) then
      Exit;
    if RunCommand('lazbuild', ['--add-package-link', APath], CommandOutput) then
      Log(CSI_Yellow, 'added ' + APath);
  finally
    Filter.Free;
  end;
end;

procedure TMakeRunner.RegisterAllPackagesLazbuild(const ASearchDir: string);
var
  List: TStringList;
  Each: string;
begin
  List := TProjectFiles.FindAll(ASearchDir, '*.lpk');
  try
    for Each in List do
      RegisterPackageLazbuild(Each);
  finally
    List.Free;
  end;
end;

procedure TMakeRunner.InstallDependencies;
var
  DepDirs: TStringList;
  I: Integer;
begin
  DepDirs := TStringList.Create;
  try
    if Length(Dependencies) > 0 then
    begin
      InitSslForDownloads;
      for I := 0 to High(Dependencies) do
        DepDirs.Add(ResolveDependency(Dependencies[I]));
    end;

    if UsesLazbuild then
    begin
      for I := 0 to DepDirs.Count - 1 do
        RegisterAllPackagesLazbuild(DepDirs[I]);
      RegisterAllPackagesLazbuild(GetCurrentDir);
    end
    else
    begin
      for I := 0 to DepDirs.Count - 1 do
        FGraph.DiscoverUnder(DepDirs[I]);
      FGraph.DiscoverUnder(GetCurrentDir);
      if FGraph.PackageCount > 0 then
        FGraph.BuildAll;
    end;
  finally
    DepDirs.Free;
  end;
end;

function TMakeRunner.ExtractBinaryFromBuildLog(const AOutput,
  AFallback: string): string;
var
  Line: string;
  Parts: TStringArray;
  I: Integer;
begin
  Result := AFallback;
  for Line in SplitString(AOutput, LineEnding) do
    if ContainsStr(Line, 'Linking') then
    begin
      Parts := SplitString(Line, ' ');
      for I := High(Parts) downto 0 do
      begin
        if Trim(Parts[I]) <> '' then
        begin
          Result := Trim(Parts[I]);
          Break;
        end;
      end;
      Exit;
    end;
end;

function TMakeRunner.BuildProjectWithLazbuild(const APath: string): string;
var
  BuildOutput: AnsiString;
begin
  Result := '';
  if RunCommand('lazbuild', ['--build-all', '--recursive',
    '--no-write-project', APath], BuildOutput) then
  begin
    Result := ExtractBinaryFromBuildLog(string(BuildOutput), '');
    if Result <> '' then
      Log(CSI_Green, ' -> ' + Result)
    else
      WriteLn(stderr, string(BuildOutput));
  end
  else
  begin
    WriteLn(stderr, string(BuildOutput));
    IncError;
    ReportBuildErrors(string(BuildOutput));
  end;
end;

function TMakeRunner.BuildProjectWithFpc(const APath: string): string;
var
  Proj: TLpiProject;
  ExtraPaths, Args: TStringList;
  BuildOutput: AnsiString;
  ArgArray: array of string;
  I: Integer;
begin
  Result := '';
  Proj := TLpiProject.CreateFromFile(APath, FTargetCpu, FTargetOs);
  try
    if not Proj.IsValid then
    begin
      Log(CSI_Red, 'invalid project: ' + APath);
      IncError;
      Exit;
    end;

    ForceDirectories(ExtractFilePath(Proj.TargetBinary));
    ExtraPaths := FGraph.UnitPathsForRequired(Proj.RequiredPackageNames);
    try
      Args := Proj.BuildFpcArgv(ExtraPaths, FTargetCpu, FTargetOs);
      try
        SetLength(ArgArray, Args.Count);
        for I := 0 to Args.Count - 1 do
          ArgArray[I] := Args[I];
        if RunCommand('fpc', ArgArray, BuildOutput) then
        begin
          WriteLn(stderr, string(BuildOutput));
          Result := ExtractBinaryFromBuildLog(string(BuildOutput), Proj.TargetBinary);
          if FileExists(Result) then
            Log(CSI_Green, ' -> ' + Result)
          else
          begin
            Log(CSI_Red, 'fpc reported success but binary missing: ' + Proj.TargetBinary);
            IncError;
          end;
        end
        else
        begin
          WriteLn(stderr, string(BuildOutput));
          IncError;
          ReportBuildErrors(string(BuildOutput));
        end;
      finally
        Args.Free;
      end;
    finally
      ExtraPaths.Free;
    end;
  finally
    Proj.Free;
  end;
end;

function TMakeRunner.BuildProject(const ALpiPath: string): string;
begin
  Result := '';
  LogInline(CSI_Yellow, 'build from ' + ALpiPath);
  try
    if UsesLazbuild then
      Result := BuildProjectWithLazbuild(ALpiPath)
    else
      Result := BuildProjectWithFpc(ALpiPath);
  except
    on E: Exception do
    begin
      WriteLn(stderr);
      IncError;
      Log(CSI_Red, E.ClassName + ': ' + E.Message);
    end;
  end;
end;

function TMakeRunner.IsGUIProject(const ALpiPath: string): Boolean;
var
  Content: string;
  Filter: TRegExpr;
begin
  Result := False;
  if not FileExists(ALpiPath) then
    Exit;
  Content := TLazXml.ReadFile(ALpiPath);
  Filter := TRegExpr.Create('<PackageName\s+Value="LCL"\s*/>');
  try
    Result := Filter.Exec(Content);
  finally
    Filter.Free;
  end;
end;

function TMakeRunner.IsTestProject(const ALpiPath: string): Boolean;
var
  LprPath, Content: string;
begin
  Result := False;
  LprPath := ChangeFileExt(ALpiPath, '.lpr');
  if not FileExists(LprPath) then
    Exit;
  Content := TLazXml.ReadFile(LprPath);
  Result := Pos('consoletestrunner', Content) > 0;
end;

procedure TMakeRunner.RunTestProject(const APath: string);
var
  BinaryPath: string;
  TestOutput: AnsiString;
begin
  BinaryPath := BuildProject(APath);
  if BinaryPath = '' then
    Exit;
  try
    if RunCommand(BinaryPath, ['--all', '--format=plain', '--progress'],
      TestOutput) then
      WriteLn(stderr, string(TestOutput))
    else
    begin
      IncError;
      WriteLn(stderr, string(TestOutput));
    end;
  except
    on E: Exception do
    begin
      IncError;
      Log(CSI_Red, E.ClassName + ': ' + E.Message);
    end;
  end;
end;

procedure TMakeRunner.RunSampleProject(const APath: string);
var
  BinaryPath: string;
  SampleOutput: AnsiString;
begin
  BinaryPath := BuildProject(APath);
  if BinaryPath = '' then
    Exit;
  try
    Log(CSI_Yellow, 'run ' + BinaryPath);
    if RunCommand(BinaryPath, [], SampleOutput) then
      WriteLn(string(SampleOutput))
    else
    begin
      IncError;
      Log(CSI_Red, 'sample execution failed: ' + BinaryPath);
      WriteLn(stderr, string(SampleOutput));
    end;
  except
    on E: Exception do
    begin
      IncError;
      Log(CSI_Red, E.ClassName + ': ' + E.Message);
    end;
  end;
end;

procedure TMakeRunner.BuildAllProjects;
var
  List: TStringList;
  Each: string;
begin
  List := TProjectFiles.FindAll(Target, '*.lpi');
  try
    for Each in List do
    begin
      if IsGUIProject(Each) then
      begin
        Log(CSI_Yellow, 'skip GUI project ' + Each);
        Continue;
      end;

      if IsTestProject(Each) then
        RunTestProject(Each)
      else
        RunSampleProject(Each);
    end;
  finally
    List.Free;
  end;
end;

function TMakeRunner.Execute: Integer;
begin
  InitEnvironment;
  UpdateSubmodules;
  InstallDependencies;
  BuildAllProjects;
  ReportSummary;
  Result := FErrorCount;
end;

// ---------------------------------------------------------------------------
// Program entry
// ---------------------------------------------------------------------------

var
  Runner: TMakeRunner;
begin
  Runner := TMakeRunner.Create;
  try
    ExitCode := Runner.Execute;
  finally
    Runner.Free;
  end;
end.
