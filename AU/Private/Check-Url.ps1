
function Check-Url([string]$Url, [int] $Timeout)
{
    $response = request $Url $Timeout
    if ($response.ContentType -like '*text/html*') {
        throw "URL content type is text/html: '$Url'"
    }
}
