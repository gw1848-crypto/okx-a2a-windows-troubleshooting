using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;

internal static class Program
{
    private static int Main(string[] args)
    {
        string userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        string codexHome = Path.Combine(userProfile, ".okx-agent-task", "codex-home");
        string sqliteHome = Path.Combine(codexHome, "sqlite");
        Directory.CreateDirectory(codexHome);
        Directory.CreateDirectory(sqliteHome);

        string codex = Environment.GetEnvironmentVariable("OKX_A2A_REAL_CODEX_COMMAND");
        if (string.IsNullOrWhiteSpace(codex) || !File.Exists(codex))
        {
            string binRoot = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "OpenAI", "Codex", "bin");

            if (Directory.Exists(binRoot))
            {
                codex = Directory.GetFiles(binRoot, "codex.exe", SearchOption.AllDirectories)
                    .OrderByDescending(File.GetLastWriteTimeUtc)
                    .FirstOrDefault();
            }
        }

        if (string.IsNullOrWhiteSpace(codex) || !File.Exists(codex))
        {
            Console.Error.WriteLine("A2A Codex wrapper: codex.exe was not found.");
            return 127;
        }

        var startInfo = new ProcessStartInfo
        {
            FileName = codex,
            Arguments = string.Join(" ", args.Select(QuoteWindowsArgument)),
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        startInfo.EnvironmentVariables["CODEX_HOME"] = codexHome;
        startInfo.EnvironmentVariables["CODEX_SQLITE_HOME"] = sqliteHome;

        using (Process process = Process.Start(startInfo))
        {
            Thread stdout = new Thread(() =>
                process.StandardOutput.BaseStream.CopyTo(Console.OpenStandardOutput()));
            Thread stderr = new Thread(() =>
                process.StandardError.BaseStream.CopyTo(Console.OpenStandardError()));
            stdout.Start();
            stderr.Start();
            process.WaitForExit();
            stdout.Join();
            stderr.Join();
            return process.ExitCode;
        }
    }

    private static string QuoteWindowsArgument(string value)
    {
        if (value.Length == 0)
            return "\"\"";

        if (!value.Any(c => char.IsWhiteSpace(c) || c == '\"'))
            return value;

        var result = new StringBuilder();
        result.Append('\"');
        int backslashes = 0;

        foreach (char c in value)
        {
            if (c == '\\')
            {
                backslashes++;
                continue;
            }

            if (c == '\"')
            {
                result.Append('\\', backslashes * 2 + 1);
                result.Append('\"');
                backslashes = 0;
                continue;
            }

            result.Append('\\', backslashes);
            backslashes = 0;
            result.Append(c);
        }

        result.Append('\\', backslashes * 2);
        result.Append('\"');
        return result.ToString();
    }
}
