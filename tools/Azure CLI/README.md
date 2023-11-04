# Snippets

## Set azure account

```powershell
# az account clear;
# az login;
az account list --output table;
az account set --subscription "Visual Studio Enterprise Subscription";
```

# Add additional extensions

```powershell
az config set extension.use_dynamic_install=yes_without_prompt;
az extension add --name containerapp --upgrade;
az provider register --namespace Microsoft.App;
az provider register --namespace Microsoft.OperationalInsights;
```


## Call the script

```powershell
.\runme.ps1 -var-file production.env
```

> [!NOTE]
> The script will generate a `output.md`` file containing GitHub Secrets and Variables that needs to be added to the repository settings.
