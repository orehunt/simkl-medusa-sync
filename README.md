# Simkl Medusa Sync
Sync A [Medusa] instance with your [simkl] _watching_ list. It will remove all series from medusa that are NOT present in your simkl _watching_ list, and it will add all series from the simkl _watching_ list that are NOT already present in medusa.

# Setup

Docker compose example:

``` yaml
simkl-medusa-sync:
    image: untoreh/simkl-medusa-sync
    container_name: simkl-medusa-sync
    restart: unless-stopped
    volumes:
        - ./simkl_medusa_sync:/config
```

# Config
Make sure a simkl `client_id` and `redirect_uri` is present in the `simkl_creds.json` config file. (Located in your config directory). On first start it will prompt for simkl pin procedure to get a valid access token.
Some variables for configuration:
- `XDG_CACHE_HOME` is the path of your config dir.
- `MEDUSA_URL` is the path (including port) of the medusa server.
- `SYNC_SLEEP` is how frequently should the sync happen (default to `8h`).


[Medusa]: https://github.com/pymedusa/Medusa
[simkl]: https://simkl.com/
