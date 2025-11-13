{
  description = "Some garnix actions";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:NixOS/nixpkgs?ref=nixpkgs-unstable";
  };


  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = nixpkgs.legacyPackages.${system}; in
      {
        lib = let
        in rec {
          /*
            A helper to get a GitHub Personal Access Token (PAT).

            The PAT is then encrypted for the specific garnix action.
          */
          getGitHubPAT = {
            appName,
            appDescription,
            actionName,
            encryptedTokenFile,
            extraRecipientsFile ? null,
          }: flake-utils.lib.mkApp { drv = pkgs.writeShellApplication {
            name = "getGitHubPAT";
            runtimeInputs = with pkgs; [
              python3
              xdg-utils
              age
            ];
            text =
            let
              recipientsFileStr = if extraRecipientsFile == null
                then ""
                else "--recipients-file ${extraRecipientsFile}";
            in ''
              URL=$(git remote get-url origin)
              RE="^(https|git)(:\/\/|@)([^\/:]+)[\/:]([^\/:]+)\/(.+)(.git)*$"
              if [[ $URL =~ $RE ]]; then
               HOSTNAME=''${BASH_REMATCH[3]}
               OWNER=''${BASH_REMATCH[4]}
               REPO=$(basename "''${BASH_REMATCH[5]}" .git)
              else
               printf "Could not parse remote\n"
               exit 1
              fi

              ENCODED_NAME=$(python3 -c "import urllib.parse; print (urllib.parse.quote(''''${appName}''''))")
              ENCODED_DESCRIPTION=$(python3 -c "import urllib.parse; print (urllib.parse.quote(''''${appDescription}''''))")

              if [[ "$HOSTNAME" != "github.com" ]]; then
               printf "Only GitHub remotes are supported\n"
               exit 1
              fi

              PUB_KEY=$(curl --silent "https://garnix.io/api/keys/$OWNER/$REPO/actions/${actionName}/key.public")

              printf "Repo owner: %s. Repo name: %s\n" "$OWNER" "$REPO"

              printf "We need a personal access token (PAT) for this. "
              printf "Visit the following link to create a token:\n\n https://github.com/settings/personal-access-tokens/new?name=%s&description=%s&target_name=$OWNER&expires_in=30&pull_requests=write&contents=read\n\n" "$ENCODED_NAME" "$ENCODED_DESCRIPTION"
              printf "We suggest limiting the repository access to only the needed repo.\n"
              read -r -s -p "Input the token generated (will not be echoed): " TOKEN

              echo "$TOKEN" | age --encrypt ${recipientsFileStr} --recipient "$PUB_KEY" --output ${encryptedTokenFile}
            '';
          }; };

          /*
           Attempts to mimic the CI environment as much as possible. In
           particular, sets all the GARNIX_* environment variables to sensible
           values (which can however be overriden).

           You should source this string at the beginning of your bash script.

           */

          withCIEnvironment = pkgs.writeText "withCIEnvironment" ''
            GARNIX_COMMIT_SHA=''${GARNIX_COMMIT_SHA:=$(git rev-parse HEAD)}
            GARNIX_BRANCH=''${GARNIX_BRANCH:=$(git rev-parse --abbrev-ref HEAD)}

            export GARNIX_COMMIT_SHA
            export GARNIX_BRANCH
          '';

          /*
           A generic reviewdog-based linter
           */
          reviewDog = {
            actionName,
            linter,
            errorFormat ? "%f:$l%:%c: %m",
            format ? null,
            logLevel ? "info",
            encryptedTokenFile,
            extraRecipientsFile ? null,
          }: flake-utils.lib.mkApp { drv = pkgs.writeShellApplication {
              name = "reviewdog";
              runtimeInputs = with pkgs; [
                reviewdog
                age
              ];
              excludeShellChecks = [
                "SC1091"
              ];
              text =
              let fmt = if format == null
                then "-efm='${errorFormat}'"
                else "-f=${format}";
              in ''
                source ${withCIEnvironment}

                URL=$(git remote get-url origin)
                RE="^(https|git)(:\/\/|@)([^\/:]+)[\/:]([^\/:]+)\/(.+)(.git)*$"
                if [[ $URL =~ $RE ]]; then
                 CI_REPO_OWNER=''${BASH_REMATCH[4]}
                 CI_REPO_NAME=$(basename "''${BASH_REMATCH[5]}" .git)
                else
                 printf "Could not parse remote\n"
                 exit 1
                fi
                export CI_REPO_OWNER
                export CI_REPO_NAME
                CI_COMMIT="$GARNIX_COMMIT_SHA"
                export CI_COMMIT
                REVIEWDOG_GITHUB_API_TOKEN=$(age --decrypt --identity "$GARNIX_ACTION_PRIVATE_KEY_FILE" ${encryptedTokenFile})
                export REVIEWDOG_GITHUB_API_TOKEN
                # Prevent a non-zero exit code from the linter preventing
                # reviewdog from running
                set +e
                OUTFILE=$(mktemp)
                ${pkgs.writeShellScript "linter" linter} > "$OUTFILE"
                EXIT_CODE=$?
                set -e
                if [[ "$EXIT_CODE" != 0 ]]; then
                  echo "Linter exited non-zero"
                fi
                cat "$OUTFILE"
                echo "Running reviewdog"
                cat "$OUTFILE" | reviewdog -log-level=${logLevel} -reporter=github-pr-review ${fmt} -guess -tee
                exit "$EXIT_CODE"
              '';
            };} // {
              setup = self.lib.${system}.getGitHubPAT {
                inherit actionName encryptedTokenFile extraRecipientsFile;
                appName = "reviewdog ${actionName}";
                appDescription = "reviewdog via garnix actions";
              };
            };


          /*
            Run statix and upload comments as pull-request comments
            */
          statix =
            { actionName,
              encryptedTokenFile,
              disabled ? [],
              ignore ? [],
              logLevel ? "info",
              extraRecipientsFile ? null,
            }:
            let
              config = pkgs.writeText "statix.toml" ''
                disabled = [ ${toString disabled} ]
              '';
              ignoredStr = if ignore == []
                then ""
                else "--ignore ${toString ignore}";
            in self.lib.${system}.reviewDog {
              inherit actionName encryptedTokenFile logLevel extraRecipientsFile;
              linter = ''
                ${pkgs.statix}/bin/statix ${ignoredStr} check . --config ${config} -o errfmt;
              '';
              errorFormat = "%f>%l:%c:%.%#:%.%#:%m";
            };

          /*
            Run clippy and upload comments as pull-request comments
            */
          clippy =
            { actionName,
              encryptedTokenFile,
              manifestPath ? "Cargo.toml",
              logLevel ? "info",
              extraRecipientsFile ? null,
            } :
            self.lib.${system}.reviewDog {
              inherit actionName encryptedTokenFile logLevel extraRecipientsFile;
              linter = ''
                PATH=$PATH:${pkgs.cargo}/bin:${pkgs.clippy}/bin
                cargo clippy --manifest-path ${manifestPath} -q --message-format short 2>&1
              '';
              errorFormat = "%f:%l:%c: %m";
            };

        };

        apps = {
          statix = self.lib.${system}.statix
            { actionName = "statix";
              encryptedTokenFile = "./secrets/reviewDogToken";
            };
          clippy = self.lib.${system}.clippy
            { actionName = "clippy";
              manifestPath = "./tests/clippy/Cargo.toml";
              encryptedTokenFile = "./secrets/clippyToken";
              extraRecipientsFile = ./secrets/recipients.txt;
              logLevel = "debug";
            };
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            age
            statix
            reviewdog
            clippy
            cargo
          ];
        };
      }
    );
}
