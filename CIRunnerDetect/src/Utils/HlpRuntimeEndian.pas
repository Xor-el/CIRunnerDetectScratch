unit HlpRuntimeEndian;

{$I ..\Include\HashLib.inc}

interface

type
  TRuntimeEndian = class sealed
  public
    class function IsLittleEndian(): Boolean; static;
    class function AsString(): string; static;
    class function CompileTimeAsString(): string; static;
  end;

implementation

class function TRuntimeEndian.IsLittleEndian(): Boolean;
var
  N: Cardinal;
begin
  N := 1;
  Result := PByte(@N)^ = 1;
end;

class function TRuntimeEndian.AsString(): string;
begin
  if IsLittleEndian() then
    Result := 'little'
  else
    Result := 'big';
end;

class function TRuntimeEndian.CompileTimeAsString(): string;
begin
{$IF DEFINED(FPC_LITTLE_ENDIAN) OR DEFINED(HASHLIB_LITTLE_ENDIAN)}
  Result := 'little';
{$ELSEIF DEFINED(FPC_BIG_ENDIAN)}
  Result := 'big';
{$ELSE}
  Result := 'unknown';
{$IFEND}
end;

end.
