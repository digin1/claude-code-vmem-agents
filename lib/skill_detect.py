#!/usr/bin/env python3
"""Detect project tech stack from file markers.

Scans the project directory for framework indicators:
- package.json → Node.js ecosystem (Next.js, React, Vue, Express, etc.)
- pyproject.toml / requirements.txt → Python ecosystem (FastAPI, Django, Flask)
- go.mod → Go
- Cargo.toml → Rust
- docker-compose.yml → Docker
- And more...

Usage: skill_detect.py <project_dir>
Output: JSON with detected frameworks
"""
import sys
import json
import os
import re


def detect_node_frameworks(project_dir):
    """Detect Node.js frameworks from package.json."""
    pkg_path = os.path.join(project_dir, "package.json")
    if not os.path.exists(pkg_path):
        return []

    try:
        with open(pkg_path) as f:
            pkg = json.load(f)
    except Exception:
        return []

    deps = {}
    deps.update(pkg.get("dependencies", {}))
    deps.update(pkg.get("devDependencies", {}))

    frameworks = []

    # Map package names to framework identifiers
    node_map = {
        "next": ("nextjs", "Next.js"),
        "react": ("react", "React"),
        "vue": ("vue", "Vue.js"),
        "@angular/core": ("angular", "Angular"),
        "express": ("express", "Express.js"),
        "svelte": ("svelte", "Svelte"),
        "nuxt": ("nuxt", "Nuxt"),
        "astro": ("astro", "Astro"),
        "@remix-run/node": ("remix", "Remix"),
        "remix": ("remix", "Remix"),
        "@nestjs/core": ("nestjs", "NestJS"),
        "gatsby": ("gatsby", "Gatsby"),
        "vite": ("vite", "Vite"),
        "tailwindcss": ("tailwindcss", "Tailwind CSS"),
        "@prisma/client": ("prisma", "Prisma"),
        "prisma": ("prisma", "Prisma"),
        "drizzle-orm": ("drizzle", "Drizzle ORM"),
        "mongoose": ("mongoose", "Mongoose"),
        "typescript": ("typescript", "TypeScript"),
        "playwright": ("playwright", "Playwright"),
        "@playwright/test": ("playwright", "Playwright"),
        "jest": ("jest", "Jest"),
        "vitest": ("vitest", "Vitest"),
        "cypress": ("cypress", "Cypress"),
        "three": ("threejs", "Three.js"),
        "socket.io": ("socketio", "Socket.IO"),
        "graphql": ("graphql", "GraphQL"),
        "@apollo/server": ("apollo", "Apollo GraphQL"),
        "trpc": ("trpc", "tRPC"),
        "@trpc/server": ("trpc", "tRPC"),
        "electron": ("electron", "Electron"),
        "expo": ("expo", "Expo (React Native)"),
        "react-native": ("react-native", "React Native"),
    }

    seen = set()
    for pkg_name, (fid, fname) in node_map.items():
        if pkg_name in deps and fid not in seen:
            seen.add(fid)
            frameworks.append({
                "id": fid,
                "name": fname,
                "version": deps[pkg_name],
                "ecosystem": "node"
            })

    return frameworks


def detect_python_frameworks(project_dir):
    """Detect Python frameworks from pyproject.toml, requirements.txt, setup.py."""
    frameworks = []

    python_map = {
        r"\bfastapi\b": ("fastapi", "FastAPI"),
        r"\bdjango\b": ("django", "Django"),
        r"\bflask\b": ("flask", "Flask"),
        r"\bcelery\b": ("celery", "Celery"),
        r"\bsqlalchemy\b": ("sqlalchemy", "SQLAlchemy"),
        r"\bpydantic\b": ("pydantic", "Pydantic"),
        r"\bpandas\b": ("pandas", "Pandas"),
        r"\bnumpy\b": ("numpy", "NumPy"),
        r"\bpytest\b": ("pytest", "Pytest"),
        r"\bscrapy\b": ("scrapy", "Scrapy"),
        r"\bstreamlit\b": ("streamlit", "Streamlit"),
        r"\bgradio\b": ("gradio", "Gradio"),
        r"\blangchain\b": ("langchain", "LangChain"),
        r"\bdask\b": ("dask", "Dask"),
        r"\btorch\b": ("pytorch", "PyTorch"),
        r"\btensorflow\b": ("tensorflow", "TensorFlow"),
        r"\banthropic\b": ("anthropic-sdk", "Anthropic SDK"),
        r"\bopenai\b": ("openai-sdk", "OpenAI SDK"),
        r"\bscikit-learn\b": ("sklearn", "Scikit-learn"),
        r"\bmatplotlib\b": ("matplotlib", "Matplotlib"),
        r"\bpolars\b": ("polars", "Polars"),
        r"\bhttpx\b": ("httpx", "HTTPX"),
        r"\baiohttp\b": ("aiohttp", "aiohttp"),
        r"\buvicorn\b": ("uvicorn", "Uvicorn"),
        r"\balembic\b": ("alembic", "Alembic"),
        r"\bplaywright\b": ("playwright-python", "Playwright (Python)"),
    }

    # Collect all dependency text
    dep_text = ""
    for fname in ["requirements.txt", "requirements-dev.txt",
                   "requirements/base.txt", "requirements/dev.txt",
                   "requirements/production.txt"]:
        fpath = os.path.join(project_dir, fname)
        if os.path.exists(fpath):
            try:
                with open(fpath) as f:
                    dep_text += f.read().lower() + "\n"
            except Exception:
                pass

    # pyproject.toml
    pyproject_path = os.path.join(project_dir, "pyproject.toml")
    if os.path.exists(pyproject_path):
        try:
            with open(pyproject_path) as f:
                dep_text += f.read().lower() + "\n"
        except Exception:
            pass

    # setup.py / setup.cfg
    for fname in ["setup.py", "setup.cfg"]:
        fpath = os.path.join(project_dir, fname)
        if os.path.exists(fpath):
            try:
                with open(fpath) as f:
                    dep_text += f.read().lower() + "\n"
            except Exception:
                pass

    # Pipfile
    pipfile_path = os.path.join(project_dir, "Pipfile")
    if os.path.exists(pipfile_path):
        try:
            with open(pipfile_path) as f:
                dep_text += f.read().lower() + "\n"
        except Exception:
            pass

    if not dep_text:
        return []

    seen = set()
    for pattern, (fid, fname) in python_map.items():
        if fid not in seen and re.search(pattern, dep_text):
            seen.add(fid)
            frameworks.append({
                "id": fid,
                "name": fname,
                "ecosystem": "python"
            })

    return frameworks


def detect_go_frameworks(project_dir):
    """Detect Go frameworks from go.mod."""
    gomod_path = os.path.join(project_dir, "go.mod")
    if not os.path.exists(gomod_path):
        return []

    frameworks = [{"id": "go", "name": "Go", "ecosystem": "go"}]

    try:
        with open(gomod_path) as f:
            content = f.read().lower()
    except Exception:
        return frameworks

    go_map = {
        "github.com/gin-gonic/gin": ("gin", "Gin"),
        "github.com/gofiber/fiber": ("fiber", "Fiber"),
        "github.com/labstack/echo": ("echo", "Echo"),
        "github.com/gorilla/mux": ("gorilla-mux", "Gorilla Mux"),
        "gorm.io/gorm": ("gorm", "GORM"),
        "github.com/jackc/pgx": ("pgx", "pgx (PostgreSQL)"),
        "github.com/stretchr/testify": ("testify", "Testify"),
        "github.com/spf13/cobra": ("cobra", "Cobra CLI"),
        "github.com/spf13/viper": ("viper", "Viper Config"),
        "google.golang.org/grpc": ("grpc-go", "gRPC Go"),
        "github.com/nats-io/nats.go": ("nats", "NATS"),
    }

    for module, (fid, fname) in go_map.items():
        if module in content:
            frameworks.append({"id": fid, "name": fname, "ecosystem": "go"})

    return frameworks


def detect_rust_frameworks(project_dir):
    """Detect Rust frameworks from Cargo.toml."""
    cargo_path = os.path.join(project_dir, "Cargo.toml")
    if not os.path.exists(cargo_path):
        return []

    frameworks = [{"id": "rust", "name": "Rust", "ecosystem": "rust"}]

    try:
        with open(cargo_path) as f:
            content = f.read().lower()
    except Exception:
        return frameworks

    rust_map = {
        "actix-web": ("actix", "Actix Web"),
        "axum": ("axum", "Axum"),
        "rocket": ("rocket", "Rocket"),
        "tokio": ("tokio", "Tokio"),
        "serde": ("serde", "Serde"),
        "diesel": ("diesel", "Diesel ORM"),
        "sqlx": ("sqlx", "SQLx"),
        "clap": ("clap", "Clap CLI"),
        "warp": ("warp", "Warp"),
        "tonic": ("tonic", "Tonic gRPC"),
    }

    for crate, (fid, fname) in rust_map.items():
        if crate in content:
            frameworks.append({"id": fid, "name": fname, "ecosystem": "rust"})

    return frameworks


def detect_infra_tools(project_dir):
    """Detect Docker, K8s, Terraform, CI/CD, etc."""
    frameworks = []

    checks = [
        ("docker-compose.yml", "docker-compose", "Docker Compose"),
        ("docker-compose.yaml", "docker-compose", "Docker Compose"),
        ("compose.yml", "docker-compose", "Docker Compose"),
        ("compose.yaml", "docker-compose", "Docker Compose"),
        ("Dockerfile", "docker", "Docker"),
        (".github/workflows", "github-actions", "GitHub Actions"),
        (".gitlab-ci.yml", "gitlab-ci", "GitLab CI"),
        ("Jenkinsfile", "jenkins", "Jenkins"),
        ("Makefile", "make", "Make"),
        ("CMakeLists.txt", "cmake", "CMake"),
        ("build.gradle", "gradle", "Gradle"),
        ("build.gradle.kts", "gradle", "Gradle"),
        ("pom.xml", "maven", "Maven"),
        ("nginx.conf", "nginx", "Nginx"),
        ("ansible.cfg", "ansible", "Ansible"),
        ("playbook.yml", "ansible", "Ansible"),
        ("pulumi.yaml", "pulumi", "Pulumi"),
        ("serverless.yml", "serverless", "Serverless Framework"),
        ("fly.toml", "fly", "Fly.io"),
        ("railway.json", "railway", "Railway"),
        ("vercel.json", "vercel", "Vercel"),
        ("netlify.toml", "netlify", "Netlify"),
        ("render.yaml", "render", "Render"),
        ("Procfile", "heroku", "Heroku"),
    ]

    seen = set()
    for marker, fid, fname in checks:
        if fid in seen:
            continue
        path = os.path.join(project_dir, marker)
        if os.path.exists(path):
            seen.add(fid)
            frameworks.append({"id": fid, "name": fname, "ecosystem": "infra"})

    # Terraform (.tf files)
    try:
        for f in os.listdir(project_dir):
            if f.endswith(".tf"):
                frameworks.append({"id": "terraform", "name": "Terraform", "ecosystem": "infra"})
                break
    except Exception:
        pass

    # Kubernetes (check common dirs)
    for kdir in ["k8s", "kubernetes", ".k8s", "deploy/k8s", "deploy/kubernetes",
                  "manifests", "charts", "helm"]:
        if os.path.isdir(os.path.join(project_dir, kdir)):
            frameworks.append({"id": "kubernetes", "name": "Kubernetes", "ecosystem": "infra"})
            break

    # Helm (Chart.yaml)
    if os.path.exists(os.path.join(project_dir, "Chart.yaml")):
        if "kubernetes" not in seen:
            frameworks.append({"id": "kubernetes", "name": "Kubernetes", "ecosystem": "infra"})
        frameworks.append({"id": "helm", "name": "Helm", "ecosystem": "infra"})

    return frameworks


def detect_ruby_frameworks(project_dir):
    """Detect Ruby frameworks from Gemfile."""
    gemfile_path = os.path.join(project_dir, "Gemfile")
    if not os.path.exists(gemfile_path):
        return []

    frameworks = [{"id": "ruby", "name": "Ruby", "ecosystem": "ruby"}]

    try:
        with open(gemfile_path) as f:
            content = f.read().lower()
    except Exception:
        return frameworks

    # Match both single and double quoted gem names: gem 'rails' or gem "rails"
    ruby_map = {
        "rails": ("rails", "Ruby on Rails"),
        "sinatra": ("sinatra", "Sinatra"),
        "rspec": ("rspec", "RSpec"),
        "sidekiq": ("sidekiq", "Sidekiq"),
    }

    for gem_name, (fid, fname) in ruby_map.items():
        # Match gem 'name' or gem "name" patterns
        if re.search(rf"""gem\s+['\"]{gem_name}['\"]""", content):
            frameworks.append({"id": fid, "name": fname, "ecosystem": "ruby"})

    return frameworks


def detect_java_frameworks(project_dir):
    """Detect Java/Kotlin frameworks from build files."""
    frameworks = []

    for build_file in ["pom.xml", "build.gradle", "build.gradle.kts"]:
        fpath = os.path.join(project_dir, build_file)
        if os.path.exists(fpath):
            try:
                with open(fpath) as f:
                    content = f.read().lower()
            except Exception:
                continue

            if "spring" in content:
                frameworks.append({"id": "spring", "name": "Spring Boot", "ecosystem": "java"})
            if "quarkus" in content:
                frameworks.append({"id": "quarkus", "name": "Quarkus", "ecosystem": "java"})
            if "micronaut" in content:
                frameworks.append({"id": "micronaut", "name": "Micronaut", "ecosystem": "java"})
            break

    return frameworks


def detect_stack(project_dir):
    """Main detection function — runs all detectors."""
    if not os.path.isdir(project_dir):
        return {"frameworks": [], "project_dir": project_dir, "project_name": ""}

    frameworks = []
    frameworks.extend(detect_node_frameworks(project_dir))
    frameworks.extend(detect_python_frameworks(project_dir))
    frameworks.extend(detect_go_frameworks(project_dir))
    frameworks.extend(detect_rust_frameworks(project_dir))
    frameworks.extend(detect_ruby_frameworks(project_dir))
    frameworks.extend(detect_java_frameworks(project_dir))
    frameworks.extend(detect_infra_tools(project_dir))

    # Deduplicate by id
    seen = set()
    unique = []
    for fw in frameworks:
        if fw["id"] not in seen:
            seen.add(fw["id"])
            unique.append(fw)

    return {
        "frameworks": unique,
        "project_dir": project_dir,
        "project_name": os.path.basename(os.path.normpath(project_dir))
    }


if __name__ == "__main__":
    project_dir = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    result = detect_stack(project_dir)
    print(json.dumps(result))
