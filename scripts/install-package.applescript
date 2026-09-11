on run arguments
  if (count of arguments) is not 1 then error "Expected one package path."
  set packagePath to item 1 of arguments
  set installCommand to "/usr/sbin/installer -pkg " & quoted form of packagePath & " -target /"
  do shell script installCommand with administrator privileges
end run
