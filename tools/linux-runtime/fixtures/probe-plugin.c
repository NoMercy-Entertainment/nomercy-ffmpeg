#include <pthread.h>
#include <stdint.h>
#include <stdio.h>

static pthread_key_t plugin_key;
static uint64_t plugin_value = UINT64_C(0x2222222222222222);
static unsigned destructor_count, wrong_destructor_values;

static void plugin_destructor(void *pointer)
{
    destructor_count++;
    if (pointer != &plugin_value)
        wrong_destructor_values++;
    fprintf(stderr, "plugin destructor: pointer=%p expected=%p\n",
            pointer, (void *)&plugin_value);
}

int plugin_create(void) { return pthread_key_create(&plugin_key, plugin_destructor); }
unsigned plugin_key_id(void) { return (unsigned)plugin_key; }
void *plugin_expected_value(void) { return &plugin_value; }
int plugin_set_value(void) { return pthread_setspecific(plugin_key, &plugin_value); }
void *plugin_get_value(void) { return pthread_getspecific(plugin_key); }
unsigned plugin_destructor_count(void) { return destructor_count; }
unsigned plugin_wrong_destructor_values(void) { return wrong_destructor_values; }
