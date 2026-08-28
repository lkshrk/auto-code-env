data "coder_workspace_preset" "routivo" {
  name        = "routivo"
  description = "Routivo monorepo"
  parameters = {
    variant           = "full"
    access            = "routivo"
    repos             = "git@github.com:routivo/routivo-monorepo.git"
    deployment_url    = "https://routivo.h-cloud.io"
    enable_dind       = "true"
    enable_playwright = "true"
    cpu               = "6"
    memory            = "32"
  }
}

data "coder_workspace_preset" "civora" {
  name        = "civora"
  description = "Civora monorepo"
  parameters = {
    variant           = "full"
    access            = "civora"
    repos             = "git@github.com:loc-news/civora-monorepo.git"
    deployment_url    = "https://neustadt.civora.news"
    enable_dind       = "true"
    enable_playwright = "true"
    cpu               = "6"
    disk_size         = "50"
  }
}

data "coder_workspace_preset" "omni" {
  name = "omni"
  parameters = {
    variant = "go"
    repos   = "git@github.com:lkshrk/omni.git"
    cpu     = "6"
  }
}

data "coder_workspace_preset" "easy_web_gpg" {
  name = "easy-web-gpg"
  parameters = {
    variant        = "go"
    repos          = "git@github.com:lkshrk/Easy-Web-GPG.git"
    deployment_url = "https://gpg.h-cloud.lan"
  }
}

data "coder_workspace_preset" "sonarr_season_reminder" {
  name = "sonarr-season-reminder"
  parameters = {
    variant = "python"
    repos   = "git@github.com:lkshrk/sonarr-season-reminder.git"
  }
}

data "coder_workspace_preset" "signal_cli_seerr_plugin" {
  name = "signal-cli-seerr-plugin"
  parameters = {
    variant = "lua"
    repos   = "git@github.com:lkshrk/signal-cli-seerr-plugin.git"
  }
}

data "coder_workspace_preset" "skeletoni" {
  name = "skeletoni"
  parameters = {
    variant           = "ts"
    repos             = "git@github.com:lkshrk/skeletoni.git"
    enable_playwright = "true"
  }
}

data "coder_workspace_preset" "directus_reply_to_mail" {
  name = "directus-extension-reply-to-mail"
  parameters = {
    variant = "ts"
    repos   = "git@github.com:lkshrk/directus-extension-reply-to-mail.git"
  }
}

data "coder_workspace_preset" "rybbit_oidc" {
  name = "rybbit-oidc"
  parameters = {
    variant           = "ts"
    repos             = "git@github.com:lkshrk/rybbit-oidc.git"
    deployment_url    = "https://analytics.h-cloud.io"
    enable_playwright = "true"
  }
}

data "coder_workspace_preset" "pfalz_herz" {
  name = "pfalz-herz"
  parameters = {
    variant           = "ts"
    access            = "pub"
    repos             = "git@github.com:webdev-harke/pfalz-herz.git"
    deployment_url    = "https://pfalz-herz.pub.h-cloud.io"
    enable_dind       = "true"
    enable_playwright = "true"
  }
}

data "coder_workspace_preset" "pizzeria_riva" {
  name = "pizzeria-riva"
  parameters = {
    variant           = "ts"
    access            = "pub"
    repos             = "git@github.com:webdev-harke/pizzeria-riva.git"
    deployment_url    = "https://pizzeria-riva.pub.h-cloud.io"
    enable_dind       = "true"
    enable_playwright = "true"
  }
}

data "coder_workspace_preset" "isc" {
  name = "isc"
  parameters = {
    variant           = "ts"
    access            = "pub"
    repos             = "git@github.com:webdev-harke/ISC.git"
    deployment_url    = "https://isc.pub.h-cloud.io"
    enable_dind       = "true"
    enable_playwright = "true"
  }
}

data "coder_workspace_preset" "quintessenz" {
  name = "quintessenz"
  parameters = {
    variant           = "ts"
    access            = "pub"
    repos             = "git@github.com:webdev-harke/quintessenz-horst.git"
    deployment_url    = "https://quintessenz-horst.de"
    enable_dind       = "true"
    enable_playwright = "true"
  }
}

data "coder_workspace_preset" "portfolio" {
  name = "portfolio"
  parameters = {
    variant           = "ts"
    access            = "pub"
    repos             = "git@github.com:webdev-harke/portfolio.git"
    deployment_url    = "https://portfolio.harke.me"
    enable_dind       = "true"
    enable_playwright = "true"
  }
}

data "coder_workspace_preset" "gitops" {
  name = "gitops"
  parameters = {
    variant = "full"
    repos   = "git@github.com:lkshrk/h-cloud.git"
  }
}
