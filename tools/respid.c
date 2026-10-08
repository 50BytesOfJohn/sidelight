// prints "pid responsible_pid comm" for every process; uses private libsystem call
#include <stdio.h>
#include <stdlib.h>
#include <libproc.h>
#include <sys/types.h>
extern pid_t responsibility_get_pid_responsible_for_pid(pid_t);
int main(void){
  int n = proc_listallpids(NULL,0); pid_t *p = malloc(sizeof(pid_t)*(n+64));
  n = proc_listallpids(p, sizeof(pid_t)*(n+64));
  for(int i=0;i<n;i++){ char name[256]={0}; proc_name(p[i],name,sizeof name);
    printf("%d %d %s\n", p[i], responsibility_get_pid_responsible_for_pid(p[i]), name);}
  return 0;}
