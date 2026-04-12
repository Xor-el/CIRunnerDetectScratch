program CIRunnerDetectDemo;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

{$APPTYPE CONSOLE}

uses
  SysUtils,
  CpuCompareReport;

begin
  try
    RunCpuCapabilityCompare;
  except
    on E: Exception do
      WriteLn(E.ClassName, ': ', E.Message);
  end;
end.
