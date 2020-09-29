# Specs

1. Endpoint/URL
    * rather than `/zip_download` use `/download` to make it more generic/extensible

2. Upstream download failures
    * Client download should be all-or-nothing and fail as soon as soon as any upstream response fails (including auth expiry)
    * _Can the client can do head requests to check all upstream files before get request?_
    * On failure return 502 to the client with HTML response listing failed URLs and associated response codes

    ```
    502 Bad Gateway
    The following files could not be fetched:
    https://server1.com/document1.doc  [401 Unauthorized]
    https://server2.com/document2.doc  [404 Not Found]
    https://server3.com/document3.doc  [500 Internal Server Error]
    ```


3. Filenames
    * Downloading upstream files should respect the content-dispostion header and name the file accordingly
    * If there is no content disposition, the file should be named the basename of the URL `File.basename(URI.parse(uri))`
    * If the basename has no extension it will be included as-is without extension (that's responsibility of data owner)
    * If there is more than one file with the same name, the file should be placed in a subdirectory inside the zip
    * The subdirectory should be uniquely named by stepping back through the URI until a difference is detected, eg
    ```
        https://data1.server1.com/a/b/c/document.doc
        https://data1.server1.com/a/y/z/document.doc

        b_c/document.doc
        y_z/document.doc
    ```
    ``` 
        https://data1.server1.com/a/b/c/document.doc
        https://data1.server1.com/a/y/z/document.doc
        https://data2.server1.com/a/y/z/document.doc

        data1_server1_com_a_b_c/document.doc
        data1_server1_com_a_y_z/document.doc
        data2_server1_com_a_y_z/document.doc
    ```

4. Request for single files
    * If the client requests a single file, it will still be zipped for consistency (the downstream app is responsible)