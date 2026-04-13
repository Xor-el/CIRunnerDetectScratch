unit CpuCompareReport;

{$I ..\..\CIRunnerDetect\src\Include\HashLib.inc}

interface

procedure RunCpuCapabilityCompare;

implementation

uses
  SysUtils, Classes, Process, HlpSimdLevels, HlpCpuFeatures;

const
  NetColUnavailable = '(unavailable)';

function TrimProbeLog(const S: string): string;
const
  MaxLines = 40;
  MaxChars = 8000;
var
  SL: TStringList;
  I: Integer;
  Line, Sep: string;
begin
  Result := '';
  if S = '' then
    Exit;
  SL := TStringList.Create;
  try
    SL.Text := S;
    for I := 0 to SL.Count - 1 do
    begin
      if I >= MaxLines then
      begin
        if Result <> '' then
          Result := Result + LineEnding;
        Result := Result + '[... truncated ...]';
        Break;
      end;
      Line := SL[I];
      if Result = '' then
        Sep := ''
      else
        Sep := LineEnding;
      if Length(Result) + Length(Sep) + Length(Line) > MaxChars then
      begin
        if Result <> '' then
          Result := Result + LineEnding;
        Result := Result + '[... truncated ...]';
        Break;
      end;
      Result := Result + Sep + Line;
    end;
  finally
    SL.Free;
  end;
end;

function FindCpuProbeCsProj: string;
const
  RelPaths: array[0..2] of string = (
    'CpuProbe' + PathDelim + 'CpuProbe.csproj',
    '..' + PathDelim + 'CpuProbe' + PathDelim + 'CpuProbe.csproj',
    '..' + PathDelim + '..' + PathDelim + 'CpuProbe' + PathDelim + 'CpuProbe.csproj'
  );
var
  Base, P: string;
  I, J: Integer;
begin
  Result := '';
  Base := ExtractFilePath(ParamStr(0));
  for J := 0 to 8 do
  begin
    for I := Low(RelPaths) to High(RelPaths) do
    begin
      P := ExpandFileName(IncludeTrailingPathDelimiter(Base) + RelPaths[I]);
      if FileExists(P) then
        Exit(P);
    end;
    Base := ExpandFileName(IncludeTrailingPathDelimiter(Base) + '..');
  end;
end;

function IsValidProbeKey(const K: string): Boolean;
var
  I: Integer;
begin
  Result := Length(K) >= 2;
  if not Result then
    Exit;
  for I := 1 to Length(K) do
    case K[I] of
      'A'..'Z', 'a'..'z', '0'..'9', '_':
        ;
    else
      Exit(False);
    end;
end;

procedure CollectDataLines(const ARaw: string; AOut: TStrings);
var
  SL: TStringList;
  K: Integer;
  S: string;
  Eq: Integer;
begin
  AOut.Clear;
  SL := TStringList.Create;
  try
    SL.Text := ARaw;
    for K := 0 to SL.Count - 1 do
    begin
      S := Trim(SL[K]);
      Eq := Pos('=', S);
      if (Eq < 2) or (Eq >= Length(S)) then
        Continue;
      if Pos(' ', Copy(S, 1, Eq - 1)) > 0 then
        Continue;
      if not IsValidProbeKey(Trim(Copy(S, 1, Eq - 1))) then
        Continue;
      AOut.Add(S);
    end;
  finally
    SL.Free;
  end;
end;

function NativeValueStr(const Lines: TStrings; const Key: string): string;
var
  I, P: Integer;
  K, U: string;
begin
  Result := '';
  U := UpperCase(Key);
  for I := 0 to Lines.Count - 1 do
  begin
    P := Pos('=', Lines[I]);
    if P < 2 then
      Continue;
    K := UpperCase(Trim(Copy(Lines[I], 1, P - 1)));
    if K <> U then
      Continue;
    Result := Trim(Copy(Lines[I], P + 1, MaxInt));
    Exit;
  end;
end;

function NativeInt(const Lines: TStrings; const Key: string): Integer;
var
  S: string;
begin
  S := NativeValueStr(Lines, Key);
  if S = '' then
    Exit(-999);
  if S = '-1' then
    Exit(-1);
  Result := StrToIntDef(S, -999);
end;

function X86LevelToStr(const L: TX86SimdLevel): string;
begin
  case L of
    TX86SimdLevel.Scalar:
      Result := 'scalar';
    TX86SimdLevel.SSE2:
      Result := 'sse2';
    TX86SimdLevel.SSSE3:
      Result := 'ssse3';
    TX86SimdLevel.AVX2:
      Result := 'avx2';
  else
    Result := 'unknown';
  end;
end;

function ArmLevelToStr(const L: TArmSimdLevel): string;
begin
  case L of
    TArmSimdLevel.Scalar:
      Result := 'scalar';
    TArmSimdLevel.NEON:
      Result := 'neon';
    TArmSimdLevel.SVE:
      Result := 'sve';
    TArmSimdLevel.SVE2:
      Result := 'sve2';
  else
    Result := 'unknown';
  end;
end;

function BoolTxt(B: Boolean): string;
begin
  if B then
    Result := 'True'
  else
    Result := 'False';
end;

function NativeBoolTxt(V: Integer): string;
begin
  case V of
    -999:
      Result := '(missing)';
    -1:
      Result := 'n/a';
    1:
      Result := 'True';
  else
    Result := 'False';
  end;
end;

function ComparableMatch(const HashB: Boolean; NativeV: Integer): Boolean;
begin
  if (NativeV = -1) or (NativeV = -999) then
    Exit(True);
  Result := HashB = (NativeV = 1);
end;

function MatchTxt(const HashB: Boolean; NativeV: Integer): string;
begin
  if (NativeV = -1) or (NativeV = -999) then
    Exit('-');
  if HashB = (NativeV = 1) then
    Result := 'yes'
  else
    Result := 'NO';
end;

procedure PrintHeader;
begin
  WriteLn(Format('%-24s %14s %14s %10s', ['Feature', 'HashLib', '.NET', 'Match']));
  WriteLn(StringOfChar('-', 66));
end;

procedure PrintRow(const AFeature, AHash, ANet, AMatch: string);
begin
  WriteLn(Format('%-24s %14s %14s %10s', [AFeature, AHash, ANet, AMatch]));
end;

procedure Summarize(const Mis: TStrings; const DotNetProbeOk: Boolean);
var
  I: Integer;
begin
  WriteLn('');
  if not DotNetProbeOk then
    WriteLn('Summary: .NET probe unavailable; HashLib-only rows above.')
  else if Mis.Count = 0 then
    WriteLn('Summary: all comparable features match.')
  else
  begin
    Write('Summary: MISMATCH on: ');
    for I := 0 to Mis.Count - 1 do
    begin
      if I > 0 then
        Write(', ');
      Write(Mis[I]);
    end;
    WriteLn;
  end;
end;

{$IFDEF HASHLIB_X86}
procedure ReportX86(const Lines: TStrings; const DotNetProbeOk: Boolean);
var
  Mis: TStringList;
  HL, NL: string;

  procedure RowBool(const Title, Key: string; const HB: Boolean);
  var
    N: Integer;
  begin
    if not DotNetProbeOk then
      PrintRow(Title, BoolTxt(HB), NetColUnavailable, '-')
    else
    begin
      N := NativeInt(Lines, Key);
      PrintRow(Title, BoolTxt(HB), NativeBoolTxt(N), MatchTxt(HB, N));
      if not ComparableMatch(HB, N) then
        Mis.Add(Title);
    end;
  end;

begin
  Mis := TStringList.Create;
  try
    PrintHeader;
    HL := X86LevelToStr(TCpuFeatures.X86.GetActiveSimdLevel());
    if not DotNetProbeOk then
      PrintRow('Simd level', HL, NetColUnavailable, '-')
    else
    begin
      NL := NativeValueStr(Lines, 'SIMDLVL');
      if NL = '' then
        NL := '(missing)';
      if SameText(HL, NL) then
        PrintRow('Simd level', HL, NL, 'yes')
      else
      begin
        PrintRow('Simd level', HL, NL, 'NO');
        Mis.Add('Simd level');
      end;
    end;

    RowBool('SSE2', 'SSE2', TCpuFeatures.X86.HasSSE2());
    RowBool('SSSE3', 'SSSE3', TCpuFeatures.X86.HasSSSE3());
    RowBool('AVX2', 'AVX2', TCpuFeatures.X86.HasAVX2());
    RowBool('PCLMULQDQ', 'PCLMULQDQ', TCpuFeatures.X86.HasPCLMULQDQ());
    RowBool('VPCLMULQDQ', 'VPCLMULQDQ', TCpuFeatures.X86.HasVPCLMULQDQ());
    RowBool('AES-NI', 'AESNI', TCpuFeatures.X86.HasAESNI());
    RowBool('SHA-NI (Intel)', 'SHANI', TCpuFeatures.X86.HasSHANI());

    Summarize(Mis, DotNetProbeOk);
  finally
    Mis.Free;
  end;
end;
{$ENDIF}

{$IFDEF HASHLIB_ARM}
procedure ReportArm(const Lines: TStrings; const DotNetProbeOk: Boolean);
var
  Mis: TStringList;
  HL, NL: string;

  procedure RowBool(const Title, Key: string; const HB: Boolean);
  var
    N: Integer;
  begin
    if not DotNetProbeOk then
      PrintRow(Title, BoolTxt(HB), NetColUnavailable, '-')
    else
    begin
      N := NativeInt(Lines, Key);
      PrintRow(Title, BoolTxt(HB), NativeBoolTxt(N), MatchTxt(HB, N));
      if not ComparableMatch(HB, N) then
        Mis.Add(Title);
    end;
  end;

begin
  Mis := TStringList.Create;
  try
    PrintHeader;
    HL := ArmLevelToStr(TCpuFeatures.Arm.GetActiveSimdLevel());
    if not DotNetProbeOk then
      PrintRow('Simd level', HL, NetColUnavailable, '-')
    else
    begin
      NL := NativeValueStr(Lines, 'SIMDLVL');
      if NL = '' then
        NL := '(missing)';
      if SameText(HL, NL) then
        PrintRow('Simd level', HL, NL, 'yes')
      else
      begin
        PrintRow('Simd level', HL, NL, 'NO');
        Mis.Add('Simd level');
      end;
    end;

    RowBool('NEON', 'NEON', TCpuFeatures.Arm.HasNEON());
    RowBool('SVE', 'SVE', TCpuFeatures.Arm.HasSVE());
    RowBool('SVE2', 'SVE2', TCpuFeatures.Arm.HasSVE2());
    RowBool('AES', 'AES', TCpuFeatures.Arm.HasAES());
    RowBool('SHA1', 'SHA1', TCpuFeatures.Arm.HasSHA1());
    RowBool('SHA256', 'SHA256', TCpuFeatures.Arm.HasSHA256());
    RowBool('SHA512', 'SHA512', TCpuFeatures.Arm.HasSHA512());
    RowBool('SHA3', 'SHA3', TCpuFeatures.Arm.HasSHA3());
    RowBool('CRC32', 'CRC32', TCpuFeatures.Arm.HasCRC32());
    RowBool('PMULL', 'PMULL', TCpuFeatures.Arm.HasPMULL());

    Summarize(Mis, DotNetProbeOk);
  finally
    Mis.Free;
  end;
end;
{$ENDIF}

procedure RunCpuCapabilityCompare;
var
  ProbePath: string;
  RawOut: AnsiString;
  Lines: TStringList;
  DotNetProbeOk: Boolean;
  Preview: string;
begin
  Lines := TStringList.Create;
  try
    DotNetProbeOk := False;
    RawOut := '';
    ProbePath := FindCpuProbeCsProj;

    if ProbePath <> '' then
    begin
      DotNetProbeOk := RunCommand('dotnet', ['run', '--project', ProbePath, '-c', 'Release',
        '--nologo'], RawOut);
      if DotNetProbeOk then
        CollectDataLines(string(RawOut), Lines)
      else
        Lines.Clear;
    end;

    WriteLn('--- CIRunnerDetectDemo: HashLib vs .NET intrinsics ---');
    if ProbePath <> '' then
      WriteLn('CpuProbe: ', ProbePath)
    else
      WriteLn('CpuProbe: (project file not found)');
    WriteLn('');

    if not DotNetProbeOk then
    begin
      if ProbePath = '' then
        WriteLn('.NET CpuProbe: skipped (CpuProbe.csproj not found).')
      else
      begin
        WriteLn('.NET CpuProbe: dotnet run failed. Log excerpt:');
        Preview := TrimProbeLog(string(RawOut));
        if Preview <> '' then
          WriteLn(Preview)
        else
          WriteLn('(no output captured)');
      end;
      WriteLn('');
    end;

{$IFDEF HASHLIB_X86}
    ReportX86(Lines, DotNetProbeOk);
{$ELSE}
{$IFDEF HASHLIB_ARM}
    ReportArm(Lines, DotNetProbeOk);
{$ELSE}
    WriteLn('Neither HASHLIB_X86 nor HASHLIB_ARM is defined for this target.');
{$ENDIF}
{$ENDIF}
  finally
    Lines.Free;
  end;
end;

end.
