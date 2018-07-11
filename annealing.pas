{
    Simulated annealing library for FPC/Delphi.
    
    Copyright (c) F. Moukayed (2018)
    
    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
}

{$mode objfpc}

unit annealing;

interface

type
    { Annealing scheduler abstract base class }
    TSAScheduler = class
        function Temperature(I : qword) : real; virtual; abstract;
    end;

    { Exponential annealing scheduler }
    TSAExponentialScheduler = class(TSAScheduler)
        private
            T0 : real;
            Decay : real;
        public
            constructor Create(T : real; N : qword);
            function Temperature(I : qword) : real; override;
    end;

    { Linear annealing scheduler }
    TSALinearScheduler = class(TSAScheduler)
        private
            T0 : real;
            N : qword;
        public
            constructor Create(T : real; Limit : qword);
            function Temperature(I : qword) : real; override;
    end;

    { Generic optimization problem interface }
    generic TSAProblem<T> = class
        function Next(var S : T) : T; virtual; abstract;
        function Energy(const S : T) : real; virtual; abstract;
    end;

    { Minimizer }
    generic TSASolver<T> = class
        type
            TProblem = specialize TSAProblem<T>;
        private
            Problem : TProblem;
            Scheduler : TSAScheduler;
            FSI : T;
            FSmin : T;
            FI : qword;
            FTI : real;
            FImproved : boolean;
        private
            function GetLoop() : boolean;
        public
            constructor Create(P : TProblem; S : TSAScheduler; S0 : T);
            procedure Restart(S0 : T);
            procedure Solve;
            property Smin : T read FSmin;
            property SI : T read FSI;
            property I : qword read FI;
            property TI : real read FTI;
            property Improved : boolean read FImproved;
            property Loop : boolean read GetLoop;
    end;

{ Transition acceptance function }
function SAaccept(T : real; D : real) : boolean;

implementation

const
    EPSILON : real = 0.001;

{****************************************************************************
                            TSAExponentialScheduler
 ****************************************************************************}

constructor TSAExponentialScheduler.Create(T : real; N : qword);
begin
    T0 := T;
    Decay := Ln(EPSILON / T0) / N;
end;

function TSAExponentialScheduler.Temperature(I : qword) : real;
var
    TI : real;
begin
    TI := T0 * Exp(Decay * I);
    if TI < EPSILON then
        Result := 0.0
    else
        Result := TI;
end;

{****************************************************************************
                            TSALinearScheduler
 ****************************************************************************}

constructor TSALinearScheduler.Create(T : real; Limit : qword);
begin
    T0 := T;
    N := Limit;
end;

function TSALinearScheduler.Temperature(I : qword) : real;
begin
    Result := (1 - I / N) * T0;
end;

{****************************************************************************
                                    TSASolver
 ****************************************************************************}

constructor TSASolver.Create(P : TProblem; S : TSAScheduler; S0 : T);
begin
    Problem := P;
    Scheduler := S;
    Restart(S0);
end;

procedure TSASolver.Restart(S0 : T);
begin
    FSI := S0;
    FSmin := S0;
    FI := 0;
    FTI := Scheduler.Temperature(FI);
end;

procedure TSASolver.Solve;
var
    SJ : T;
    DT : real;
begin
    { Check if temperature is higher than 0 }
    if FTI > 0 then
    begin
        { Transition to next state }
        SJ := Problem.Next(FSI);
        { Calculate energy difference between states }
        DT := Problem.Energy(SJ) - Problem.Energy(FSI);
        { Check whether transition should be accepted }
        if SAaccept(FTI, DT) then
        begin
            { Set current state to the next state (SJ) }
            FSI := SJ;
            { Check if the new state's energy is less than the current minimum }
            if Problem.Energy(FSI) < Problem.Energy(Smin) then
            begin
                { Update minimum, set improved flag }
                FSmin := FSI;
                FImproved := true;
            end
            else
            begin
                FImproved := false;
            end;
        end
        else
        begin
            FImproved := false;
        end;
        { Increase iteration counter, update temperature for the new iteration }
        Inc(FI);
        FTI := Scheduler.Temperature(FI);
    end;
end;

function TSASolver.GetLoop() : boolean;
begin
    Result := FTI > 0;
end;

{****************************************************************************
                                Utilities
 ****************************************************************************}

function SAaccept(T : real; D : real): boolean;
begin
    if D < 0 then
        Result := true
    else
        Result := Random <= Exp(-D / T);
end;

end.
