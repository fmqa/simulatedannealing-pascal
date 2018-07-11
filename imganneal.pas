{
    Image denoising demo using simulated annealing.
    
    Copyright (c) F. Moukayed (2018)
    
    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
}


{$mode objfpc}

program imganneal;

uses sysutils, getopts, math, unix, classes, FPImage, FPWriteBMP, annealing;

type
    { Annealing state }
    TImageState = record
        Energy : longword;
        Image : TFPCustomImage;
        X, Y, DX, DY : integer;
        Visited : boolean;
    end;

    TImageSolver = specialize TSASolver<TImageState>;

    TImageProblem = specialize TSAProblem<TImageState>;

    { State manipulator }
    TAdjacentEnergyProblem = class(TImageProblem)
        function Next(var S : TImageState) : TImageState; override;
        function Energy(const S : TImageState) : real; override;
    end;

const 
    USAGE : PChar = 
        'Simulated annealing pattern generator.' + LineEnding + LineEnding +
        'Options:' + LineEnding + LineEnding +
        #9'-w|--width        Output image width (default: 256).' + LineEnding +
        #9'-h|--height       Output image height (default: 256).' + LineEnding +
        #9'-t|--temperature  Initial temperature (default: 100).' + LineEnding +
        #9'-s|--steps        Iteration count (default: 100000).' + LineEnding +
        #9'-o|--output       Output bitmap file (default: anneal.bmp)' + LineEnding +
        #9'--help            Show this text.' + LineEnding;

    OPTIONS : array [1..7] of TOption = (
        (Name: 'width'; Has_arg: 1; Flag: nil; Value: #0),
        (Name: 'height'; Has_arg: 1; Flag: nil; Value: #0),
        (Name: 'steps'; Has_arg: 1; Flag: nil; Value: #0),
        (Name: 'temperature'; Has_arg: 1; Flag: nil; Value: #0),
        (Name: 'output'; Has_arg: 1; Flag: nil; Value: #0),
        (Name: 'help'; Has_arg: 0; Flag: nil; Value: #0),
        (Name: ''; Has_arg: 0; Flag: nil; Value: #0)
    );
    
    OPTSPEC : string = 'w::h::s::t::o::';

{ Fill image with noise }
procedure Noise(const Image : TFPCustomImage);
var
    X, Y : integer;
    C : TFPColor;
begin
    for Y := 0 to Image.Height - 1 do
    begin
        for X := 0 to Image.Width - 1 do
        begin
            C.red := random(65536);
            C.green := random(65536);
            C.blue := random(65536);
            C.alpha := 65535;
            Image.Colors[X, Y] := C;
        end;
    end;
end;

{ Compute Manhattan/Taxicab distance between RGB components of given colors }
function Manhattan(const P, Q : TFPColor) : longword;
var
    DR, DG, DB : longint;
begin
    DR := longint(P.red) - longint(Q.red);
    DG := longint(P.green) - longint(Q.green);
    DB := longint(P.blue) - longint(Q.blue);
    Result := abs(DR) + abs(DG) + abs(DB);
end;

{ Calculate the sum of Manhattan distances between each pixel and 
  its N, W neighbors }
function Objective(const Image : TFPCustomImage) : longword;
var
    X, Y : integer;
    S : longword;
begin
    S := 0;
    for Y := 1 to Image.Height - 1 do
    begin
        for X := 1 to Image.Width - 1 do
        begin
            S := S + Manhattan(Image.Colors[X, Y], Image.Colors[X - 1, Y]);
            S := S + Manhattan(Image.Colors[X, Y], Image.Colors[X, Y - 1]);
        end;
    end;
    Result := S;
end;

{ Swap pixel at (X, Y) with pixel at (X+DX, Y+DY) in the image state }
procedure Shuffle(const S : TImageState);
var
    T : TFPColor;
begin
    T := S.Image.Colors[S.X, S.Y];
    S.Image.Colors[S.X, S.Y] := S.Image.Colors[S.X + S.DX, S.Y + S.DY];
    S.Image.Colors[S.X + S.DX, S.Y + S.DY] := T;
end;

{ Randomize X, Y, DX, DY }
procedure Roll(var S : TImageState);
begin
    S.X := 1 + Random(S.Image.Width - 2);
    S.Y := 1 + Random(S.Image.Height - 2);
    S.DX := RandomRange(-1, 2);
    S.DY := RandomRange(-1, 2);
    { Regenerate DX, DY if DX=DY=0, since the latter would
      result in a no-op state transition }
    while (S.DX = 0) and (S.DY = 0) do
    begin
        S.DX := RandomRange(-1, 2);
        S.DY := RandomRange(-1, 2);
    end;
end;

{ Get state energy }
function TAdjacentEnergyProblem.Energy(const S : TImageState) : real;
begin
    Result := S.Energy;
end;

{ Return the next state }
function TAdjacentEnergyProblem.Next(var S : TImageState) : TImageState;
var
    U : TImageState;
begin
    { If the state has been visited before, revert the last swap
      and regenerate all random variables }
    if S.Visited then
    begin
        Shuffle(S);
        Roll(S);
    end;

    { Swap pixels and mark the current state as visited }
    Shuffle(S);
    S.Visited := true;

    { Initialize the next state and assign it the current energy }
    U.Image := S.Image;
    U.Visited := false;
    Roll(U);
    U.Energy := Objective(U.Image);

    Result := U;
end;

{ Shows help text }
procedure ShowHelpAndHalt;
begin
    writeln(USAGE);
    halt(0);
end;

{ Exclusive file locking helper }
procedure FExLockOrHalt(Handle : longint);
begin
    if fpFlock(Handle, LOCK_EX) <> 0 then
    begin
        writeln(ErrOutput, 'Failed to lock file descriptor: ', Handle);
        halt(1);
    end;
end;

{ Exclusive file unlocking helper }
procedure FExUnlockOrHalt(Handle : longint);
begin
    if fpFlock(Handle, LOCK_UN) <> 0 then
    begin
        writeln(ErrOutput, 'Failed to unlock file descriptor: ', Handle);
        halt(1);
    end;
end;

var
    C : char;
    Width : integer = 256;
    Height : integer = 256;
    Steps : qword = 100000;
    Temperature : real = 100;
    Target : String = 'anneal.bmp';
    OptIndex : longint;
    Image : TFPCustomImage;
    Writer : TFPCustomImageWriter;
    Scheduler : TSAExponentialScheduler;
    Problem : TAdjacentEnergyProblem;
    Solver : TImageSolver;
    S0 : TImageState;
    Stream : TFileStream;
begin
    C := getlongopts(OPTSPEC, @OPTIONS[1], OptIndex);
    while C <> endofoptions do
    begin
        case C of
            #0 : begin
                case OptIndex of
                    1 : Width := StrToInt(optarg);
                    2 : Height := StrToInt(optarg);
                    3 : Steps := StrToQWord(optarg);
                    4 : Temperature := StrToFloat(optarg);
                    5 : Target := optarg;
                    6 : ShowHelpAndHalt;
                end;
            end;
            'w' : Width := StrToInt(optarg);
            'h' : Height := StrToInt(optarg);
            't' : Temperature := StrToFloat(optarg);
            's' : Steps := StrToQWord(optarg);
            'o' : Target := optarg;
            '?' : halt(1);
        end;
        C := getlongopts(OPTSPEC, @OPTIONS[1], OptIndex);
    end;

    randomize;

    Stream := TFileStream.Create(Target, fmCreate);

    try
        Image := TFPMemoryImage.Create(width, height);
        Writer := TFPWriterBMP.Create;
        
        { Generate noisy image }
        Noise(Image);
        
        { Configure the initial state }
        S0.Image := Image;
        S0.Visited := false;
        S0.Energy := Objective(S0.Image);
        Roll(S0);

        { Setup minimizer and annealing schedule }
        Scheduler := TSAExponentialScheduler.Create(temperature, steps);
        Problem := TAdjacentEnergyProblem.Create;
        Solver := TImageSolver.Create(Problem, Scheduler, S0);

        { Optimization loop }
        while Solver.Loop do
        begin
            Solver.Solve;
            if Solver.I mod 100 = 0 then
                writeln('STEP', #9, 
                        'I=', Solver.I, #9, 
                        'TI=', Solver.TI:0:5, #9, 
                        'E=', Solver.SI.Energy, #9, 
                        'V=', Solver.SI.Visited);
                flush(Output);
            if Solver.Improved then
            begin
                writeln('MIN', #9, 
                        'I=', Solver.I, #9,
                        'TI=', Solver.TI:0:5, #9,
                        'E=', Solver.SI.Energy);
                flush(Output);
                { Update the image file within an exclusive advisory lock.
                  This allows us to safely copy a specific image state
                  using flock(1) }
                FExLockOrHalt(Stream.Handle);
                try
                    Image.SaveToStream(Stream, Writer);
                finally
                    FExUnlockOrHalt(Stream.Handle);
                end;
            end;
        end;
    finally
        FreeAndNil(Solver);
        FreeAndNil(Problem);
        FreeAndNil(Scheduler);
        FreeAndNil(Writer);
        FreeAndNil(Image);
        FreeAndNil(Stream);
    end;
end.

