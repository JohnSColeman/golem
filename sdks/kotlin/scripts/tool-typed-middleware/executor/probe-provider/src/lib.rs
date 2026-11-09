use golem_rust::agentic::{InputStream, OutputStream};
use golem_rust::{ToolError, tool_definition, tool_implementation};

#[derive(Debug, Clone, ToolError)]
pub enum ProbeError {
    #[tool_error(kind = "runtime-error", exit_code = 3)]
    Rejected { message: String },
    #[tool_error(kind = "usage-error", exit_code = 4)]
    Gone,
}

#[tool_definition(version = "1.0.0")]
pub trait MiddlewareProbe {
    async fn apply(&self, value: String) -> String;
    async fn check(&self, sku_id: String) -> Result<String, ProbeError>;
}

struct MiddlewareProbeImpl;

#[tool_implementation]
impl MiddlewareProbe for MiddlewareProbeImpl {
    async fn apply(&self, value: String) -> String {
        format!("leaf({value})")
    }

    async fn check(&self, sku_id: String) -> Result<String, ProbeError> {
        match sku_id.as_str() {
            "bad" => Err(ProbeError::Rejected { message: "bad sku".to_string() }),
            "gone" => Err(ProbeError::Gone),
            _ => Ok(format!("ok({sku_id})")),
        }
    }
}

#[tool_definition(version = "1.0.0")]
pub trait BackendProbe {
    async fn execute(&self, encoded: String) -> i64;
}

struct BackendProbeImpl;

#[tool_implementation]
impl BackendProbe for BackendProbeImpl {
    async fn execute(&self, encoded: String) -> i64 {
        encoded.len() as i64
    }
}

#[tool_definition(version = "1.0.0")]
pub trait ArgProbe {
    #[arg(pattern = "positional")]
    #[arg(paths = "tail")]
    #[arg(max_count = "option", short = 'm')]
    #[arg(context = "option", default = 2)]
    #[arg(include = "option", repeatable = "either", delim = ',')]
    #[arg(case_sensitive = "flag", short = 'c', negatable = true, default = false)]
    #[arg(verbose = "flag", kind = "count-flag", max = 3)]
    #[constraint(requires_all = ["pattern"])]
    #[result(formatters = [("json", "JSON report"), ("table", "Table")], default = "json", doc = "Search report")]
    #[allow(clippy::too_many_arguments)]
    async fn search(
        &self,
        pattern: String,
        paths: Vec<String>,
        max_count: Option<i32>,
        context: i32,
        include: Vec<String>,
        case_sensitive: bool,
        verbose: u32,
    ) -> String;
    async fn ping(&self) -> String;
}

struct ArgProbeImpl;

#[tool_implementation]
impl ArgProbe for ArgProbeImpl {
    async fn search(
        &self,
        pattern: String,
        paths: Vec<String>,
        max_count: Option<i32>,
        context: i32,
        include: Vec<String>,
        case_sensitive: bool,
        verbose: u32,
    ) -> String {
        format!(
            "search(pattern={pattern} paths={} max={} ctx={context} inc={} cs={case_sensitive} v={verbose})",
            paths.join("/"),
            max_count.map(|m| m.to_string()).unwrap_or_else(|| "none".to_string()),
            include.join("/"),
        )
    }

    async fn ping(&self) -> String {
        "pong".to_string()
    }
}

#[tool_definition(version = "1.0.0")]
pub trait StreamProbe {
    async fn upper(&self, stdin: Option<InputStream>, stdout: OutputStream) -> String;
    async fn plain(&self) -> String;
}

struct StreamProbeImpl;

#[tool_implementation]
impl StreamProbe for StreamProbeImpl {
    async fn upper(&self, stdin: Option<InputStream>, mut stdout: OutputStream) -> String {
        let chunks = match stdin {
            Some(reader) => reader.collect().await,
            None => Vec::new(),
        };
        let mut bytes = Vec::new();
        for chunk in chunks {
            if let Ok(part) = chunk {
                bytes.extend(part);
            }
        }
        let text = String::from_utf8_lossy(&bytes).to_uppercase();
        let _ = stdout.write(text.clone().into_bytes()).await;
        format!("{}", text.len())
    }

    async fn plain(&self) -> String {
        "plain".to_string()
    }
}

#[tool_definition(version = "1.0.0")]
pub trait GitProbe {
    #[command(subtree = Remote)]
    #[arg(verbose = "global", kind = "flag")]
    #[arg(dir = "global")]
    fn remote(&self, verbose: bool, dir: Option<String>) -> RemoteSubtree;

    async fn status(&self) -> String;
}

// A placeholder return type for the subtree dispatcher method; never used.
pub struct RemoteSubtree;

struct GitProbeImpl;

#[tool_implementation]
impl GitProbe for GitProbeImpl {
    fn remote(&self, _verbose: bool, _dir: Option<String>) -> RemoteSubtree {
        RemoteSubtree
    }

    async fn status(&self) -> String {
        "clean".to_string()
    }
}

#[tool_definition]
pub trait Remote {
    #[arg(verbose = "global", kind = "flag")]
    #[arg(dir = "global")]
    async fn add(&self, verbose: bool, dir: Option<String>, name: String, url: String) -> String;

    async fn list(&self) -> String;
}

struct RemoteImpl;

#[tool_implementation]
impl Remote for RemoteImpl {
    async fn add(&self, verbose: bool, dir: Option<String>, name: String, url: String) -> String {
        format!(
            "add(name={name} url={url} verbose={verbose} dir={})",
            dir.unwrap_or_else(|| "none".to_string())
        )
    }

    async fn list(&self) -> String {
        "origin".to_string()
    }
}
