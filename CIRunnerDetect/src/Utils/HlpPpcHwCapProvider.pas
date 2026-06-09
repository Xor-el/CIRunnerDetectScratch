unit HlpPpcHwCapProvider;

{$I ..\Include\HashLib.inc}

interface

{$IF DEFINED(HASHLIB_POWERPC)}

{$IF DEFINED(HASHLIB_LINUX) OR DEFINED(HASHLIB_BSD)}
uses
  {$IFDEF FPC}
  dl;
  {$ELSE}
  Posix.Dlfcn;
  {$ENDIF}
{$IFEND}

{ ===== PowerPC HWCAP bit definitions (from asm/cputable.h) ===== }

{$IF DEFINED(HASHLIB_LINUX) OR DEFINED(HASHLIB_BSD)}
const
  AT_HWCAP = 16;

  PPC_FEATURE_64            = UInt64($40000000);
  PPC_FEATURE_HAS_ALTIVEC   = UInt64($10000000);
  PPC_FEATURE_HAS_VSX       = UInt64($00000080);
{$IFEND}

type
  /// <summary>
  /// Provides PowerPC hardware capability information across platforms.
  /// Linux: resolves getauxval via dlsym.
  /// BSD: resolves elf_aux_info / _elf_aux_info via dlsym.
  /// </summary>
  TPpcHwCapProvider = class sealed

{$IF DEFINED(HASHLIB_LINUX)}
  strict private
  type
    TGetAuxValFunc = function(AType: UInt64): UInt64; cdecl;

  strict private
  class var
    FGetAuxVal: TGetAuxValFunc;

  private
    class procedure ResolveDynamicImports(); static;

  public
    class function GetHwCap(): UInt64; static;
{$IFEND}

{$IF DEFINED(HASHLIB_BSD)}
  strict private
  type
    TElfAuxInfoFunc = function(AAuxType: Int32; ABuf: Pointer; ABufLen: Int32): Int32; cdecl;

  strict private
  class var
    FElfAuxInfo: TElfAuxInfoFunc;

  private
    class procedure ResolveDynamicImports(); static;

  public
    class function GetHwCap(): UInt64; static;
{$IFEND}

  end;

{$IFEND} // HASHLIB_POWERPC

implementation

{$IF DEFINED(HASHLIB_POWERPC)}

{ TPpcHwCapProvider }

{$IF DEFINED(HASHLIB_LINUX)}

class procedure TPpcHwCapProvider.ResolveDynamicImports();
var
  LHandle: Pointer;
begin
  FGetAuxVal := nil;

  LHandle := dlopen(nil, RTLD_NOW);
  if LHandle = nil then
    Exit;

  try
    FGetAuxVal := TGetAuxValFunc(dlsym(LHandle, 'getauxval'));
  finally
    dlclose(LHandle);
  end;
end;

class function TPpcHwCapProvider.GetHwCap(): UInt64;
begin
  if System.Assigned(FGetAuxVal) then
    Result := FGetAuxVal(AT_HWCAP)
  else
    Result := 0;
end;

{$IFEND} // HASHLIB_LINUX

{$IF DEFINED(HASHLIB_BSD)}

class procedure TPpcHwCapProvider.ResolveDynamicImports();
var
  LHandle: Pointer;
begin
  FElfAuxInfo := nil;

  LHandle := dlopen(nil, RTLD_NOW);
  if LHandle = nil then
    Exit;

  try
    FElfAuxInfo := TElfAuxInfoFunc(dlsym(LHandle, 'elf_aux_info'));
    if not System.Assigned(FElfAuxInfo) then
      FElfAuxInfo := TElfAuxInfoFunc(dlsym(LHandle, '_elf_aux_info'));
  finally
    dlclose(LHandle);
  end;
end;

class function TPpcHwCapProvider.GetHwCap(): UInt64;
var
  LValue: UInt64;
begin
  if System.Assigned(FElfAuxInfo) then
  begin
    LValue := 0;
    if FElfAuxInfo(Int32(AT_HWCAP), @LValue, SizeOf(LValue)) = 0 then
      Result := LValue
    else
      Result := 0;
  end
  else
    Result := 0;
end;

{$IFEND} // HASHLIB_BSD

{$IF DEFINED(HASHLIB_LINUX) OR DEFINED(HASHLIB_BSD)}
initialization
  TPpcHwCapProvider.ResolveDynamicImports;
{$IFEND}

{$IFEND} // HASHLIB_POWERPC

end.
