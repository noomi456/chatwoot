<script>
import { mapActions, mapGetters } from 'vuex';

import ChatFooter from '../components/ChatFooter.vue';
import ConversationWrap from '../components/ConversationWrap.vue';
import ConversationStarters from '../components/ConversationStarters.vue';

export default {
  components: { ChatFooter, ConversationStarters, ConversationWrap },
  computed: {
    ...mapGetters({
      groupedMessages: 'conversation/getGroupedConversation',
      conversationSize: 'conversation/getConversationSize',
      allMessagesLoaded: 'conversation/getAllMessagesLoaded',
      isFetchingMessages: 'conversation/getIsFetchingList',
    }),
    conversationStarters() {
      return window.chatwootWebChannel?.conversationStarters || [];
    },
    showConversationStarters() {
      return (
        this.allMessagesLoaded &&
        !this.isFetchingMessages &&
        !this.conversationSize &&
        this.conversationStarters.length > 0
      );
    },
  },
  mounted() {
    this.$store.dispatch('conversation/setUserLastSeen');
  },
  methods: {
    ...mapActions('conversation', ['sendMessage']),
    sendStarter(prompt) {
      this.sendMessage({ content: prompt, replyTo: null });
    },
  },
};
</script>

<template>
  <div
    class="flex flex-col flex-1 overflow-hidden rounded-b-lg bg-n-slate-2 dark:bg-n-solid-1"
  >
    <div class="flex flex-1 overflow-auto">
      <ConversationWrap :grouped-messages="groupedMessages" />
    </div>
    <ConversationStarters
      v-if="showConversationStarters"
      :starters="conversationStarters"
      @select="sendStarter"
    />
    <ChatFooter class="px-5" />
  </div>
</template>
