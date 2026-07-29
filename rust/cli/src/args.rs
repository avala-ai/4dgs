// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! Argument parsing, by hand.
//!
//! Four commands, one positional and three flags. A parser for that is shorter than the
//! paragraph justifying a dependency for it, and it means the tool's whole dependency
//! tree stays the library plus the two codecs the format defines.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Command {
    Info,
    Validate,
    Inspect,
    Decode,
}

#[derive(Debug, Clone)]
pub struct Args {
    pub command: Command,
    pub file: String,
    pub json: bool,
    pub names: bool,
    pub time: f64,
}

impl Args {
    /// `Ok(None)` when the request was `--help` or `--version`: served, with nothing left
    /// to run.
    pub fn parse(argv: &[String]) -> Result<Option<Args>, String> {
        let mut it = argv.iter();
        let first = match it.next() {
            Some(first) => first.as_str(),
            None => {
                crate::print_usage();
                return Ok(None);
            }
        };
        match first {
            "-h" | "--help" | "help" => {
                crate::print_usage();
                return Ok(None);
            }
            "-V" | "--version" | "version" => {
                out!("{}", env!("CARGO_PKG_VERSION"));
                return Ok(None);
            }
            _ => {}
        }
        let command = match first {
            "info" => Command::Info,
            "validate" => Command::Validate,
            "inspect" => Command::Inspect,
            "decode" => Command::Decode,
            other => return Err(format!("unknown command `{other}`")),
        };

        let mut args = Args {
            command,
            file: String::new(),
            json: false,
            names: false,
            time: 0.0,
        };
        let mut file: Option<String> = None;
        while let Some(arg) = it.next() {
            match arg.as_str() {
                "--json" => args.json = true,
                "--names" => args.names = true,
                "-t" | "--time" => {
                    let value = it
                        .next()
                        .ok_or_else(|| format!("{arg} needs a value in seconds"))?;
                    args.time = parse_time(value)?;
                }
                // `--time=1.5` as well as `--time 1.5`: both spellings are common enough
                // that refusing one is a papercut rather than a principle.
                other if other.starts_with("--time=") => {
                    args.time = parse_time(&other["--time=".len()..])?;
                }
                "-h" | "--help" => {
                    crate::print_usage();
                    return Ok(None);
                }
                other if other.starts_with('-') && other != "-" => {
                    return Err(format!("unknown option `{other}`"));
                }
                other => {
                    if file.replace(other.to_string()).is_some() {
                        return Err(format!("more than one file given (`{other}` is extra)"));
                    }
                }
            }
        }
        args.file = file.ok_or("a file is required")?;

        // Refused here rather than ignored: a flag that silently does nothing teaches a
        // user that it worked.
        if args.json && matches!(command, Command::Info | Command::Validate) {
            return Err(format!(
                "--json is not available for `{}`",
                name_of(command)
            ));
        }
        if args.names && command != Command::Info {
            return Err(format!(
                "--names is not available for `{}`",
                name_of(command)
            ));
        }
        if args.time != 0.0 && command != Command::Decode {
            return Err(format!(
                "--time is not available for `{}`",
                name_of(command)
            ));
        }
        Ok(Some(args))
    }
}

fn name_of(command: Command) -> &'static str {
    match command {
        Command::Info => "info",
        Command::Validate => "validate",
        Command::Inspect => "inspect",
        Command::Decode => "decode",
    }
}

/// A time has to be a real number of seconds. NaN would silently select no chunks and
/// report an empty scene, which reads like an answer rather than a rejected input.
fn parse_time(raw: &str) -> Result<f64, String> {
    match raw.parse::<f64>() {
        Ok(t) if t.is_finite() => Ok(t),
        _ => Err(format!("`{raw}` is not a time in seconds")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(argv: &[&str]) -> Result<Option<Args>, String> {
        let owned: Vec<String> = argv.iter().map(|s| s.to_string()).collect();
        Args::parse(&owned)
    }

    #[test]
    fn a_command_and_a_file_is_the_whole_common_case() {
        let args = parse(&["info", "scene.4dgs"]).unwrap().unwrap();
        assert_eq!(args.command, Command::Info);
        assert_eq!(args.file, "scene.4dgs");
        assert!(!args.json);
    }

    #[test]
    fn time_takes_both_spellings() {
        assert_eq!(
            parse(&["decode", "s", "-t", "1.5"]).unwrap().unwrap().time,
            1.5
        );
        assert_eq!(
            parse(&["decode", "s", "--time=2"]).unwrap().unwrap().time,
            2.0
        );
    }

    #[test]
    fn a_flag_that_would_do_nothing_is_refused_rather_than_ignored() {
        assert!(parse(&["info", "s", "--json"]).is_err());
        assert!(parse(&["decode", "s", "--names"]).is_err());
        assert!(parse(&["inspect", "s", "-t", "1"]).is_err());
    }

    #[test]
    fn a_time_that_is_not_a_time_is_refused() {
        assert!(parse(&["decode", "s", "-t", "nan"]).is_err());
        assert!(parse(&["decode", "s", "-t", "later"]).is_err());
        assert!(parse(&["decode", "s", "-t"]).is_err());
    }

    #[test]
    fn a_missing_file_and_a_second_file_are_both_errors() {
        assert!(parse(&["info"]).is_err());
        assert!(parse(&["info", "a.4dgs", "b.4dgs"]).is_err());
        assert!(parse(&["frobnicate", "a.4dgs"]).is_err());
    }

    #[test]
    fn help_and_version_are_served_rather_than_run() {
        assert!(parse(&["--help"]).unwrap().is_none());
        assert!(parse(&["--version"]).unwrap().is_none());
        assert!(parse(&[]).unwrap().is_none());
    }
}
