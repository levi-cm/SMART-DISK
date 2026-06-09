.result[]? | (
    (.update_id | tostring) + "\u001f" +
    (.message.text // "") + "\u001f" +
    ((.message.chat.id // "") | tostring) + "\u001f" +
    (.callback_query.id // "") + "\u001f" +
    ((.callback_query.from.id // "") | tostring) + "\u001f" +
    ((.callback_query.message.chat.id // "") | tostring) + "\u001f" +
    ((.callback_query.message.message_id // "") | tostring) + "\u001f" +
    (.callback_query.data // "") + "\u0000"
)
