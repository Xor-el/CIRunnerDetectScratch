unit HlpPpcSimdFeatures;

{$I ..\Include\HashLib.inc}

interface

uses
  HlpSimdLevels
{$IF DEFINED(HASHLIB_POWERPC)}
  , HlpPpcHwCapProvider
{$IFEND}
  ;

type
  TPpcSimdFeatures = class sealed
  strict private
  class var
    FActiveSimdLevel: TPpcSimdLevel;
    FHasPPC64: Boolean;

  strict private
    class function CPUHasAltiVec(): Boolean; static;
    class function CPUHasVSX(): Boolean; static;
    class function CPUHasPPC64(): Boolean; static;

  private
    class procedure ProbeHardwareAndCache(); static;

  public
    class function GetActiveSimdLevel(): TPpcSimdLevel; static;
    class function HasAltiVec(): Boolean; static;
    class function HasVSX(): Boolean; static;
    class function HasPPC64(): Boolean; static;
  end;

implementation

{ TPpcSimdFeatures }

class function TPpcSimdFeatures.CPUHasAltiVec(): Boolean;
begin
{$IF DEFINED(HASHLIB_POWERPC)}
  {$IF DEFINED(HASHLIB_LINUX) OR DEFINED(HASHLIB_BSD)}
    Result := TPpcHwCapProvider.GetHwCap() and PPC_FEATURE_HAS_ALTIVEC <> 0;
  {$ELSE}
    Result := False;
  {$IFEND}
{$ELSE}
  Result := False;
{$IFEND}
end;

class function TPpcSimdFeatures.CPUHasVSX(): Boolean;
begin
{$IF DEFINED(HASHLIB_POWERPC)}
  {$IF DEFINED(HASHLIB_LINUX) OR DEFINED(HASHLIB_BSD)}
    Result := TPpcHwCapProvider.GetHwCap() and PPC_FEATURE_HAS_VSX <> 0;
  {$ELSE}
    Result := False;
  {$IFEND}
{$ELSE}
  Result := False;
{$IFEND}
end;

class function TPpcSimdFeatures.CPUHasPPC64(): Boolean;
begin
{$IF DEFINED(HASHLIB_POWERPC)}
  {$IFDEF HASHLIB_POWERPC64}
    {$IF DEFINED(HASHLIB_LINUX) OR DEFINED(HASHLIB_BSD)}
      Result := TPpcHwCapProvider.GetHwCap() and PPC_FEATURE_64 <> 0;
    {$ELSE}
      Result := True;
    {$IFEND}
  {$ELSE}
    Result := False;
  {$ENDIF}
{$ELSE}
  Result := False;
{$IFEND}
end;

class procedure TPpcSimdFeatures.ProbeHardwareAndCache();
var
  LHasAltiVec, LHasVSX: Boolean;
begin
  LHasAltiVec := CPUHasAltiVec();
  LHasVSX := CPUHasVSX() and LHasAltiVec;

  if LHasVSX then
    FActiveSimdLevel := TPpcSimdLevel.VSX
  else if LHasAltiVec then
    FActiveSimdLevel := TPpcSimdLevel.AltiVec
  else
    FActiveSimdLevel := TPpcSimdLevel.Scalar;

  FHasPPC64 := CPUHasPPC64();
end;

class function TPpcSimdFeatures.GetActiveSimdLevel(): TPpcSimdLevel;
begin
  Result := FActiveSimdLevel;
end;

class function TPpcSimdFeatures.HasAltiVec(): Boolean;
begin
  Result := FActiveSimdLevel >= TPpcSimdLevel.AltiVec;
end;

class function TPpcSimdFeatures.HasVSX(): Boolean;
begin
  Result := FActiveSimdLevel >= TPpcSimdLevel.VSX;
end;

class function TPpcSimdFeatures.HasPPC64(): Boolean;
begin
  Result := FHasPPC64;
end;

initialization
  TPpcSimdFeatures.ProbeHardwareAndCache();

end.
