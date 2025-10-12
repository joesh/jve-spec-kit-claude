#!/bin/bash
# Repair broken parent chain for command 58

DB_PATH="/Users/joe/Documents/JVE Projects/Untitled Project.jvp"

echo "🔧 Repairing command 58 parent chain..."
echo ""

echo "Before repair:"
sqlite3 "$DB_PATH" "SELECT sequence_number, command_type, parent_sequence_number FROM commands WHERE sequence_number BETWEEN 56 AND 59 ORDER BY sequence_number;"

echo ""
echo "Fixing command 58 parent (NULL → 57)..."
sqlite3 "$DB_PATH" "UPDATE commands SET parent_sequence_number = 57 WHERE sequence_number = 58;"

echo ""
echo "After repair:"
sqlite3 "$DB_PATH" "SELECT sequence_number, command_type, parent_sequence_number FROM commands WHERE sequence_number BETWEEN 56 AND 59 ORDER BY sequence_number;"

echo ""
echo "✅ Repair complete! Restart JVEEditor."
