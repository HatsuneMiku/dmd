module d_do_test;

import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.file;
import std.format;
import std.process;
import std.random;
import std.regex;
import std.stdio;
import std.string;
import core.sys.posix.sys.wait;

void usage()
{
    write("d_do_test <input_dir> <test_name> <test_extension>\n"
          "\n"
          "   input_dir: one of: compilable, fail_compilation, runnable\n"
          "   test_name: basename of test case to run\n"
          "   test_extension: one of: d, html, or sh\n"
          "\n"
          "   example: d_do_test runnable pi d\n"
          "\n"
          "   relevant environment variables:\n"
          "      ARGS:          set to execute all combinations of\n"
          "      REQUIRED_ARGS: arguments always passed to the compiler\n"
          "      DMD:           compiler to use, ex: ../src/dmd\n"
          "      OS:            win32, win64, linux, freebsd, osx\n"
          "      RESULTS_DIR:   base directory for test results\n"
          "   windows vs non-windows portability env vars:\n"
          "      DSEP:          \\\\ or /\n"
          "      SEP:           \\ or /\n"
          "      OBJ:          .obj or .o\n"
          "      EXE:          .exe or <null>\n");
}

enum TestMode
{
    COMPILE,
    FAIL_COMPILE,
    RUN
}

struct TestArgs
{
    TestMode mode;

    bool     compileSeparately;
    string   executeArgs;
    string[] sources;
    string   permuteArgs;
    string   compileOutput;
    string   postScript;
    string   requiredArgs;
    // reason for disabling the test (if empty, the test is not disabled)
    string   disabled_reason;
    @property bool disabled() { return disabled_reason != ""; }
}

struct EnvData
{
    string all_args;
    string dmd;
    string results_dir;
    string sep;
    string dsep;
    string obj;
    string exe;
    string os;
    string model;
    string required_args;
}

bool findTestParameter(string file, string token, ref string result)
{
    auto tokenStart = std.string.indexOf(file, token);
    if (tokenStart == -1) return false;

    auto lineEndR = std.string.indexOf(file[tokenStart .. $], "\r");
    auto lineEndN = std.string.indexOf(file[tokenStart .. $], "\n");
    auto lineEnd  = lineEndR == -1 ?
        (lineEndN == -1 ? file.length : lineEndN) :
        (lineEndN == -1 ? lineEndR    : min(lineEndR, lineEndN));

    //writeln("found ", token, " in line: ", file.length, ", ", tokenStart, ", ", tokenStart+lineEnd);
    //writeln("found ", token, " in line: '", file[tokenStart .. tokenStart+lineEnd], "'");

    result = strip(file[tokenStart+token.length .. tokenStart+lineEnd]);
    // skips the :, if present
    if (result.length > 0 && result[0] == ':')
        result = strip(result[1 .. $]);

    //writeln("arg: '", result, "'");

    string result2;
    if (findTestParameter(file[tokenStart+lineEnd..$], token, result2))
        result ~= " " ~ result2;

    return true;
}

bool findOutputParameter(string file, string token, out string result, string sep)
{
    bool found = false;

    while (true)
    {
        auto istart = std.string.indexOf(file, token);
        if (istart == -1)
            break;
        found = true;

        // skips the :, if present
        if (file[istart] == ':') ++istart;

        enum embed_sep = "---";

        auto n = std.string.indexOf(file[istart .. $], embed_sep);
        enforce(n != -1);
        istart += n + embed_sep.length;
        while (file[istart] == '-') ++istart;
        if (file[istart] == '\r') ++istart;
        if (file[istart] == '\n') ++istart;

        auto iend = std.string.indexOf(file[istart .. $], embed_sep);
        enforce(iend != -1);
        iend += istart;

        result ~= file[istart .. iend];

        while (file[iend] == '-') ++iend;
        file = file[iend .. $];
    }

    if (found)
    {
        result = std.string.strip(result);
        result = result.unifyNewLine().unifyDirSep(sep);
        result = result ? result : ""; // keep non-null
    }
    return found;
}

void replaceResultsDir(ref string arguments, const ref EnvData envData)
{
    // Bash would expand this automatically on Posix, but we need to manually
    // perform the replacement for Windows compatibility.
    arguments = replace(arguments, "${RESULTS_DIR}", envData.results_dir);
}

void gatherTestParameters(ref TestArgs testArgs, string input_dir, string input_file, const ref EnvData envData)
{
    string file = cast(string)std.file.read(input_file);

    findTestParameter(file, "REQUIRED_ARGS", testArgs.requiredArgs);
    if(envData.required_args.length)
        testArgs.requiredArgs ~= " " ~ envData.required_args;
    replaceResultsDir(testArgs.requiredArgs, envData);

    if (! findTestParameter(file, "PERMUTE_ARGS", testArgs.permuteArgs))
    {
        if (testArgs.mode != TestMode.FAIL_COMPILE)
            testArgs.permuteArgs = envData.all_args;

        string unittestJunk;
        if(!findTestParameter(file, "unittest", unittestJunk))
            testArgs.permuteArgs = replace(testArgs.permuteArgs, "-unittest", "");
    }
    replaceResultsDir(testArgs.permuteArgs, envData);

    // win(32|64) doesn't support pic, nor does freebsd/64 currently
    if (envData.os == "win32" || envData.os == "win64" || envData.os == "freebsd")
    {
        auto index = std.string.indexOf(testArgs.permuteArgs, "-fPIC");
        if (index != -1)
            testArgs.permuteArgs = testArgs.permuteArgs[0 .. index] ~ testArgs.permuteArgs[index+5 .. $];
    }

    // clean up extra spaces
    testArgs.permuteArgs = strip(replace(testArgs.permuteArgs, "  ", " "));

    findTestParameter(file, "EXECUTE_ARGS", testArgs.executeArgs);
    replaceResultsDir(testArgs.executeArgs, envData);

    string extraSourcesStr;
    findTestParameter(file, "EXTRA_SOURCES", extraSourcesStr);
    testArgs.sources = [input_file];
    // prepend input_dir to each extra source file
    foreach(s; split(extraSourcesStr))
        testArgs.sources ~= input_dir ~ "/" ~ s;

    // swap / with $SEP
    if (envData.sep && envData.sep != "/")
        foreach (ref s; testArgs.sources)
            s = replace(s, "/", to!string(envData.sep));
    //writeln ("sources: ", testArgs.sources);

    string compileSeparatelyStr;
    testArgs.compileSeparately = findTestParameter(file, "COMPILE_SEPARATELY", compileSeparatelyStr);

    findTestParameter(file, "DISABLED", testArgs.disabled_reason);

    findOutputParameter(file, "TEST_OUTPUT", testArgs.compileOutput, envData.sep);

    if (findTestParameter(file, "POST_SCRIPT", testArgs.postScript))
        testArgs.postScript = replace(testArgs.postScript, "/", to!string(envData.sep));
}

string[] combinations(string argstr)
{
    string[] results;
    string[] args = split(argstr);
    long combinations = 1 << args.length;
    for (size_t i = 0; i < combinations; i++)
    {
        string r;
        bool printed = false;

        for (size_t j = 0; j < args.length; j++)
        {
            if (i & 1 << j)
            {
                if (printed)
                    r ~= " ";
                r ~= args[j];
                printed = true;
            }
        }

        results ~= r;
    }

    return results;
}

string genTempFilename(string result_path)
{
    auto a = appender!string();
    a.put(result_path);
    foreach (ref e; 0 .. 8)
    {
        formattedWrite(a, "%x", rndGen.front);
        rndGen.popFront();
    }

    return a.data;
}

int system(string command)
{
    if (!command) return std.c.process.system(null);
    const commandz = toStringz(command);
    auto status = std.c.process.system(commandz);
    if (status == -1) return status;
    version (Windows) status <<= 8;
    return status;
}

version(Windows)
{
    extern (D) bool WIFEXITED( int status )    { return ( status & 0x7F ) == 0; }
    extern (D) int  WEXITSTATUS( int status )  { return ( status & 0xFF00 ) >> 8; }
    extern (D) int  WTERMSIG( int status )     { return status & 0x7F; }
    extern (D) bool WIFSIGNALED( int status )
    {
        return ( cast(byte) ( ( status & 0x7F ) + 1 ) >> 1 ) > 0;
    }
}

void removeIfExists(in char[] filename)
{
    if (std.file.exists(filename))
        std.file.remove(filename);
}

string execute(ref File f, string command, bool expectpass, string result_path)
{
    auto filename = genTempFilename(result_path);
    scope(exit) removeIfExists(filename);

    auto rc = system(command ~ " > " ~ filename ~ " 2>&1");

    string output = readText(filename);
    f.writeln(command);
    f.write(output);

    if (WIFSIGNALED(rc))
    {
        auto value = WTERMSIG(rc);
        enforce(0 == value, "caught signal: " ~ to!string(value));
    }
    else if (WIFEXITED(rc))
    {
        auto value = WEXITSTATUS(rc);
        if (expectpass)
            enforce(0 == value, "expected rc == 0, exited with rc == " ~ to!string(value));
        else
            enforce(1 == value, "expected rc == 1, but exited with rc == " ~ to!string(value));
    }

    return output;
}

string unifyNewLine(string str)
{
    return std.regex.replace(str, regex(`\r\n|\r|\n`, "g"), "\n");
}

string unifyDirSep(string str, string sep)
{
    return std.regex.replace(str, regex(`(?<=\w\w*)/(?=\w[\w/]*\.di?\b)`, "g"), sep);
}
unittest
{
    assert(`fail_compilation/test.d(1) Error: dummy error message for 'test'`.unifyDirSep(`\`)
        == `fail_compilation\test.d(1) Error: dummy error message for 'test'`);
    assert(`fail_compilation/test.d(1) Error: at fail_compilation/test.d(2)`.unifyDirSep(`\`)
        == `fail_compilation\test.d(1) Error: at fail_compilation\test.d(2)`);

    assert(`fail_compilation/test.d(1) Error: at fail_compilation/imports/test.d(2)`.unifyDirSep(`\`)
        == `fail_compilation\test.d(1) Error: at fail_compilation\imports\test.d(2)`);
    assert(`fail_compilation/diag.d(2): Error: fail_compilation/imports/fail.d must be imported`.unifyDirSep(`\`)
        == `fail_compilation\diag.d(2): Error: fail_compilation\imports\fail.d must be imported`);
}

int main(string[] args)
{
    if (args.length != 4)
    {
        if (args.length == 2 && args[1] == "-unittest")
            return 0;
        usage();
        return 1;
    }

    string input_dir      = args[1];
    string test_name      = args[2];
    string test_extension = args[3];

    EnvData envData;
    envData.all_args      = getenv("ARGS");
    envData.results_dir   = getenv("RESULTS_DIR");
    envData.sep           = getenv("SEP");
    envData.dsep          = getenv("DSEP");
    envData.obj           = getenv("OBJ");
    envData.exe           = getenv("EXE");
    envData.os            = getenv("OS");
    envData.dmd           = replace(getenv("DMD"), "/", envData.sep);
    envData.model         = getenv("MODEL");
    envData.required_args = getenv("REQUIRED_ARGS");

    string result_path    = envData.results_dir ~ envData.sep;
    string input_file     = input_dir ~ envData.sep ~ test_name ~ "." ~ test_extension;
    string output_dir     = result_path ~ input_dir;
    string output_file    = result_path ~ input_dir ~ envData.sep ~ test_name ~ "." ~ test_extension ~ ".out";
    string test_app_dmd_base = output_dir ~ envData.sep ~ test_name ~ "_";

    TestArgs testArgs;

    switch (input_dir)
    {
        case "compilable":       testArgs.mode = TestMode.COMPILE;      break;
        case "fail_compilation": testArgs.mode = TestMode.FAIL_COMPILE; break;
        case "runnable":         testArgs.mode = TestMode.RUN;          break;
        default:
            writeln("input_dir must be one of 'compilable', 'fail_compilation', or 'runnable'");
            return 1;
    }

    gatherTestParameters(testArgs, input_dir, input_file, envData);

    writef(" ... %-30s %s%s(%s)",
            input_file,
            testArgs.requiredArgs,
            (!testArgs.requiredArgs.empty ? " " : ""),
            testArgs.permuteArgs);

    if (testArgs.disabled)
        writefln("!!! [DISABLED: %s]", testArgs.disabled_reason);
    else
        write("\n");

    removeIfExists(output_file);

    auto f = File(output_file, "a");

    foreach(i, c; combinations(testArgs.permuteArgs))
    {
        string test_app_dmd = test_app_dmd_base ~ to!string(i) ~ envData.exe;

        try
        {
            string[] toCleanup;

            auto thisRunName = genTempFilename(result_path);
            auto fThisRun = File(thisRunName, "w");
            scope(exit)
            {
                fThisRun.close();
                f.write(readText(thisRunName));
                f.writeln();
                removeIfExists(thisRunName);
            }

            string compile_output;
            if (!testArgs.compileSeparately)
            {
                string objfile = output_dir ~ envData.sep ~ test_name ~ "_" ~ to!string(i) ~ envData.obj;
                toCleanup ~= objfile;

                string command = format("%s -m%s -I%s %s %s -od%s -of%s %s%s", envData.dmd, envData.model, input_dir,
                        testArgs.requiredArgs, c, output_dir,
                        (testArgs.mode == TestMode.RUN ? test_app_dmd : objfile),
                        (testArgs.mode == TestMode.RUN ? "" : "-c "),
                        join(testArgs.sources, " "));
                version(Windows) command ~= " -map nul.map";

                compile_output = execute(fThisRun, command, testArgs.mode != TestMode.FAIL_COMPILE, result_path);
            }
            else
            {
                foreach (filename; testArgs.sources)
                {
                    string newo= result_path ~ replace(replace(filename, ".d", envData.obj), envData.sep~"imports"~envData.sep, envData.sep);
                    toCleanup ~= newo;

                    string command = format("%s -m%s -I%s %s %s -od%s -c %s", envData.dmd, envData.model, input_dir,
                        testArgs.requiredArgs, c, output_dir, filename);
                    compile_output ~= execute(fThisRun, command, testArgs.mode != TestMode.FAIL_COMPILE, result_path);
                }

                if (testArgs.mode == TestMode.RUN)
                {
                    // link .o's into an executable
                    string command = format("%s -m%s %s -od%s -of%s %s", envData.dmd, envData.model, envData.required_args, output_dir, test_app_dmd, join(toCleanup, " "));
                    version(Windows) command ~= " -map nul.map";

                    execute(fThisRun, command, true, result_path);
                }
            }

            compile_output = std.regex.replace(compile_output, regex(`^DMD v2\.[0-9]+.* DEBUG$`, "m"), "");
            compile_output = std.string.strip(compile_output);
            compile_output = compile_output.unifyNewLine();

            auto m = std.regex.match(compile_output, `Internal error: .*$`);
            enforce(!m, m.hit);

            if (testArgs.compileOutput !is null)
            {
                enforce(compile_output == testArgs.compileOutput,
                        "\nexpected:\n----\n"~testArgs.compileOutput~"\n----\nactual:\n----\n"~compile_output~"\n----\n");
            }

            if (testArgs.mode == TestMode.RUN)
            {
                toCleanup ~= test_app_dmd;
                version(Windows)
                    if (envData.model == "64")
                    {
                        toCleanup ~= test_app_dmd_base ~ to!string(i) ~ ".ilk";
                        toCleanup ~= test_app_dmd_base ~ to!string(i) ~ ".pdb";
                    }

                string command = test_app_dmd;
                if (testArgs.executeArgs) command ~= " " ~ testArgs.executeArgs;

                execute(fThisRun, command, true, result_path);
            }

            fThisRun.close();

            if (testArgs.postScript)
            {
                f.write("Executing post-test script: ");
                string prefix = "";
                version (Windows) prefix = "bash ";
                execute(f, prefix ~ testArgs.postScript ~ " " ~ thisRunName, true, result_path);
            }

            foreach (file; toCleanup) collectException(std.file.remove(file));
        }
        catch(Exception e)
        {
            // it failed but it was disabled, exit as if it was successful
            if (testArgs.disabled)
                return 0;

            f.writeln();
            f.writeln("==============================");
            f.writeln("Test failed: ", e.msg);
            f.close();

            writeln("Test failed.  The logged output:");
            writeln(cast(string)std.file.read(output_file));
            std.file.remove(output_file);
            return 1;
        }
    }

    // it was disabled but it passed! print an informational message
    if (testArgs.disabled)
        writefln(" !!! %-30s DISABLED but PASSES!", input_file);

    return 0;
}

