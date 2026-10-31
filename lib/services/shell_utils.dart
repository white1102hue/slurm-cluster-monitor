String shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";
