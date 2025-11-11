{
  description = "Some garnix actions";

  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs";

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = nixpkgs.legacyPackages.${system}; in
      {
        lib = let
        in {
          /*
            A helper to get a GitHub Personal Access Token (PAT).

            The PAT is then encrypted for the specific garnix action.
          */
          getGitHubPAT = {
            appName,
            appDescription,
            actionName,
            encryptedTokenFile
          }: flake-utils.lib.mkApp { drv = pkgs.writeShellApplication {
            name = "getGitHubPAT";
            runtimeInputs = with pkgs; [
              python3
              xdg-utils
              age
            ];
            text = ''
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

              echo "$TOKEN" | age --encrypt -r "$PUB_KEY" --output ${encryptedTokenFile}
            '';
          }; };
          reviewDog = {
            actionName,
            linter,
            errorFormat ? "%f:$l%:%c: %m",
            encryptedTokenFile
          }: flake-utils.lib.mkApp { drv = pkgs.writeShellApplication {
              name = "reviewdog";
              runtimeInputs = with pkgs; [
                reviewdog
                age
              ];
              text = ''
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
                ${linter} > "$OUTFILE"
                EXIT_CODE=$?
                echo "Running reviewdog"
                cat "$OUTFILE" | reviewdog -reporter=github-pr-review -efm="${errorFormat}" -guess
                exit "$EXIT_CODE"
              '';
            };} // {
              setupSecrets = self.lib.${system}.getGitHubPAT {
                inherit actionName encryptedTokenFile;
                appName = "reviewdog ${actionName}";
                appDescription = "reviewdog via garnix actions";
              };
            };
        };
        apps = {
          statix = self.lib.${system}.reviewDog {
            actionName = "statix";
            linter = "${pkgs.statix}/bin/statix check . -o errfmt";
            errorFormat = "%f>%l:%c:%.%#:%.%#:%m";
            encryptedTokenFile = "./secrets/reviewDogToken";
          };
        };
      }
    );
}
