@{
    # Katalog vaultu na udziale hosta (shared folder), widoczny w Win10 np. jako Z:
    VaultRoot = 'Z:\IntegrityVault'

    # Podkatalogi vaultu (tworzone automatycznie przez skrypty)
    BaselineFileName = 'baseline.aes'
    KeyRelativePath  = 'secrets\aes.key'
    CopiesRelativePath = 'trusted_copies'
    LogsRelativePath   = 'logs'

    # Źródło Event Log (wymaga jednorazowej rejestracji — robi to Install / Response)
    EventLogSource = 'IntegrityCheck'
    EventLogName   = 'Application'

    # Webhook Discord — wstaw prawdziwy URL tylko w lokalnym config/paths.psd1 (gitignore)
    DiscordWebhookUrl = 'https://discord.com/api/webhooks/CHANGE_ME/CHANGE_ME'

    # Ścieżka do allowlisty plików (względem katalogu projektu lub absolutna)
    FileScopePath = 'config\file-scope.txt'

    # Przywracaj automatycznie tylko pliki z AllowRestore = true w bazie (demo)
    AutoRestore = $true

    # Gdy $true: tylko raport (log + Discord), bez kopiowania z trusted_copies
    ReportOnly = $false
}
